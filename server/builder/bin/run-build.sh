#!/usr/bin/env bash
# One release, end to end.
#
#   update-pbf.sh   keep us-latest.osm.pbf current (Geofabrik daily diffs)
#   clip-pbf.sh     shrink it to the selected regions, unless all are selected
#   build-graph.sh  build one Valhalla graph (the expensive step)
#   cut-packs.sh    cut per-state tars out of that graph (cheap)
#   publish.py      content-address them into the docroot
#   site            copy the dashboard so the docroot is a complete site
#   push-r2.sh      upload to an S3-compatible bucket, if configured
#   purge           invalidate exactly one Cloudflare URL, if configured
#
# Valhalla has no incremental tile update (valhalla#3386, open since 2021):
# splicing rebuilt tiles into an old set produces broken routes, so a graph is
# always built whole. The region list decides both how much of the map is
# built and which packs are published, and the published set replaces the
# whole catalog. A graph already built from the same source is reused rather
# than rebuilt. See server/README.md.
#
# Camera data is not in these tiles. It stays on the live Overpass feed, so
# the urgent data is not coupled to this slow channel.
#
# Usage (inside the builder container):
#   run-build.sh [region-id ...]      default: every region in the set
#
# Environment:
#   DATA_DIR        work dir                        (default /data)
#   DOCROOT         site root nginx serves          (default /srv/tiles)
#   WWW_DIR         dashboard source files          (default: bundled /opt/flckd/site)
#   THREADS         mjolnir concurrency             (default nproc)
#   KEEP_RELEASES   releases to retain              (default 3)
#   PART_BYTES      bytes per published part        (default 134217728)
#   BUILD_ID        release id                      (default today, UTC)
#   PBF_NAME        source map file    (default us-latest.osm.pbf)
#   PBF_URL         where to fetch it  (default Geofabrik us-latest)
#   SKIP_PBF_UPDATE set to 1 to reuse the PBF on disk
#   CLIP_SOURCE     set to 0 to always build from the whole source map
#   REBUILD_GRAPH   set to 1 to rebuild a graph that matches its source
#   S3_BUCKET       set to upload after publishing; see push-r2.sh for the
#                   endpoint and credential variables (R2_BUCKET still works)
#   STATUS_FILE     private progress file for the control plane (optional)
#   CF_ZONE_ID      Cloudflare zone id              (optional; enables purge)
#   CF_API_TOKEN    token with "Cache Purge"        (optional)
#   PUBLIC_BASE_URL e.g. https://tiles.flckd.app    (required iff purging)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DATA_DIR="${DATA_DIR:-/data}"
DOCROOT="${DOCROOT:-/srv/tiles}"
THREADS="${THREADS:-$(nproc)}"
KEEP_RELEASES="${KEEP_RELEASES:-3}"
PART_BYTES="${PART_BYTES:-134217728}"
BUILD_ID="${BUILD_ID:-$(date -u +%Y-%m-%d)}"
REGION_SET="${REGION_SET:-/opt/flckd/regions/us-states.json}"
STAGING="${STAGING:-${DATA_DIR}/staging}"
WWW_DIR="${WWW_DIR:-}"
if [ -z "$WWW_DIR" ]; then
  for candidate in /opt/flckd/site /srv/www; do
    if [ -f "$candidate/index.html" ]; then WWW_DIR="$candidate"; break; fi
  done
fi

BIN="$(dirname "${BASH_SOURCE[0]}")"
started="$(date -u +%s)"
# Exported so the child scripts report progress against the same stage and do
# not reset publication flags this script already knows the answer to.
export STATUS_LOCAL_PUBLISHED=false
export STATUS_REMOTE_PUBLISHED=false
export CURRENT_STAGE=starting
# Where a child script leaves its reason for dying; see die() in common.sh.
export FATAL_FILE="${DATA_DIR}/.build-fatal"
# Regions cut-packs could not cut. The release still ships; the operator is
# told which ones are missing rather than left to count packs.
export SKIPPED_FILE="${DATA_DIR}/.build-skipped"
rm -f "$FATAL_FILE" "$SKIPPED_FILE" 2>/dev/null || true

status() {
  # Operator visibility while a multi-hour build runs. The public copy is
  # served with no-store; the private copy feeds the control plane.
  CURRENT_STAGE="$1"
  mkdir -p "$DOCROOT/v1"
  local tmp="$DOCROOT/v1/.build-status.tmp"
  cat > "$tmp" <<EOF
{"build_id":"${BUILD_ID}","stage":"$1","detail":"${2:-}",
 "started_at":"$(date -u -d "@${started}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
 "updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  mv -f "$tmp" "$DOCROOT/v1/build-status.json"
  write_status_file "$1" "${2:-}"
}

fail() { status "failed" "$1"; die "$1"; }

# This detail is shown to the operator as the cause of the failure.
abort_detail() {
  local reason=""
  if [ -f "$FATAL_FILE" ]; then
    reason="$(tr -d '\n' < "$FATAL_FILE" | cut -c1-300)"
  fi
  if [ -n "$reason" ]; then
    printf '%s failed: %s' "$CURRENT_STAGE" "$reason"
  else
    printf '%s failed (run-build.sh line %s)' "$CURRENT_STAGE" "$1"
  fi
}
trap 'status "failed" "$(abort_detail "$LINENO")"' ERR

log "=== FLCKD tile release ${BUILD_ID} ==="
log "threads=${THREADS} docroot=${DOCROOT} keep=${KEEP_RELEASES}"
TOTAL_REGIONS="$(python3 -c '
import json,sys; print(len(json.load(open(sys.argv[1]))["packs"]))' "$REGION_SET")"
if [ "$#" -gt 0 ]; then
  log "regions: $* ($# of ${TOTAL_REGIONS})"
fi

# ---------------------------------------------------------------------------
status "update-pbf"
if [ "${SKIP_PBF_UPDATE:-0}" = "1" ]; then
  log "SKIP_PBF_UPDATE=1, using the PBF already on disk"
else
  "$BIN/update-pbf.sh"
fi

PBF="${DATA_DIR}/${PBF_NAME:-us-latest.osm.pbf}"
[ -f "$PBF" ] || fail "no PBF at $PBF"
# Recorded in the manifest so the app can show users how old their roads are.
# Not the file's mtime: pyosmium rewrites the file on every update, so that
# always reads as today however stale the data is. The replication timestamp
# in the header is when the data was actually current.
OSM_DATE="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF" 2>/dev/null | cut -c1-10)"
case "$OSM_DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *)
    log "WARNING: no replication timestamp in $PBF, dating the release by file mtime"
    OSM_DATE="$(date -u -r "$PBF" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)" ;;
esac
log "source PBF: $(human "$(stat -c %s "$PBF")"), dated ${OSM_DATE}"

# ---------------------------------------------------------------------------
# Scratch and time both scale with the source, so a partial catalog builds
# from a clipped source. Clipping the whole set would cost a full pass over
# the file to arrive back at the file, so that case is left alone.
GRAPH_PBF_NAME="${PBF_NAME:-us-latest.osm.pbf}"
if [ "${CLIP_SOURCE:-1}" = "1" ] && [ "$#" -gt 0 ] && [ "$#" -lt "$TOTAL_REGIONS" ]; then
  status "build-graph" "clipping the source map to $# of ${TOTAL_REGIONS} regions"
  clipped="$("$BIN/clip-pbf.sh" "$PBF" "$@")"
  GRAPH_PBF_NAME="$(basename "$clipped")"
else
  log "building from the whole source map: $GRAPH_PBF_NAME"
fi

status "build-graph" "routing graph, the long stage"
PBF_NAME="$GRAPH_PBF_NAME" THREADS="$THREADS" "$BIN/build-graph.sh"

# ---------------------------------------------------------------------------
status "cut-packs" "per-region tars"
rm -rf "$STAGING"; mkdir -p "$STAGING"
"$BIN/cut-packs.sh" "$@"

# ---------------------------------------------------------------------------
status "publish"
python3 "$BIN/publish.py" \
  --staging  "$STAGING" \
  --docroot  "$DOCROOT" \
  --regions  "$REGION_SET" \
  --build-id "$BUILD_ID" \
  --part-bytes "$PART_BYTES" \
  --keep     "$KEEP_RELEASES" \
  --osm-data-date "$OSM_DATE"
STATUS_LOCAL_PUBLISHED=true

# The docroot is a complete site: nginx and the app read only this tree.
if [ -n "$WWW_DIR" ] && [ -f "$WWW_DIR/index.html" ] && [ -f "$WWW_DIR/logo.png" ]; then
  status "publish" "copying dashboard"
  cp -f "$WWW_DIR/index.html" "$DOCROOT/index.html.tmp" && mv -f "$DOCROOT/index.html.tmp" "$DOCROOT/index.html"
  cp -f "$WWW_DIR/logo.png"   "$DOCROOT/logo.png.tmp"   && mv -f "$DOCROOT/logo.png.tmp"   "$DOCROOT/logo.png"
else
  log "WARNING: no dashboard assets (index.html, logo.png) in WWW_DIR; the site root will 404"
fi

# ---------------------------------------------------------------------------
# Upload if a bucket is configured. The local docroot stays authoritative
# either way, so a self-hosted nginx origin and a bucket can run side by side.
# STATUS_FILE is cleared for the child so this script alone reports progress.
if [ -n "${S3_BUCKET:-}${R2_BUCKET:-}" ]; then
  status "upload" "uploading to ${S3_BUCKET:-$R2_BUCKET}"
  STATUS_FILE= "$BIN/push-r2.sh" "$DOCROOT"
  STATUS_REMOTE_PUBLISHED=true
else
  log "S3_BUCKET / R2_BUCKET unset - serving from the local docroot only"
fi

# ---------------------------------------------------------------------------
# Every pack URL contains the sha256 of its own content, so a changed pack
# arrives at a new URL and an unchanged pack keeps its old one. Nothing in
# /v1/packs/ is ever overwritten, so nothing there is ever purged. The pointer
# is the only mutable URL in the tree.
if [ -n "${CF_ZONE_ID:-}" ] && [ -n "${CF_API_TOKEN:-}" ]; then
  [ -n "${PUBLIC_BASE_URL:-}" ] || fail "PUBLIC_BASE_URL is required to purge"
  status "purge"
  log "purging ${PUBLIC_BASE_URL}/v1/manifest.json"
  # Path is case-sensitive and must match exactly: scheme, host, path, query.
  resp="$(curl --fail --silent --show-error -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"files\":[\"${PUBLIC_BASE_URL}/v1/manifest.json\"]}")" \
    || fail "cloudflare purge request failed"
  echo "$resp" | grep -q '"success":true' || fail "cloudflare purge rejected: $resp"
  log "purge accepted"
else
  log "CF_ZONE_ID / CF_API_TOKEN unset - skipping purge."
  log "manifest.json max-age is 60s, so clients pick up the release within a minute anyway."
fi

elapsed=$(( $(date -u +%s) - started ))
done_detail="$(( elapsed / 60 )) min"
if [ -s "$SKIPPED_FILE" ]; then
  done_detail="${done_detail}; not in the source map: $(cat "$SKIPPED_FILE")"
fi
status "done" "$done_detail"
log "=== release ${BUILD_ID} complete in $(( elapsed / 60 )) min ==="
