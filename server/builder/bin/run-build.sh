#!/usr/bin/env bash
# One monthly release, end to end.
#
#   update-pbf.sh   keep us-latest.osm.pbf current (Geofabrik daily diffs)
#   build-graph.sh  build one national Valhalla graph (the expensive step)
#   cut-packs.sh    cut 53 per-state tars out of that graph (cheap)
#   publish.py      content-address them into the nginx docroot
#   purge           invalidate exactly one Cloudflare URL
#
# Cadence is monthly. Valhalla has no incremental tile update (valhalla#3386,
# open since 2021): splicing rebuilt tiles into an old set produces broken
# routes, so a release is always a full rebuild. See server/README.md.
#
# Camera data is not in these tiles. It stays on the live Overpass feed, so
# the urgent data is not coupled to this slow channel.
#
# Usage (inside the builder container):
#   run-build.sh [region-id ...]      default: every region in the set
#
# Environment:
#   DATA_DIR        work dir                        (default /data)
#   DOCROOT         nginx root                      (default /srv/tiles)
#   THREADS         mjolnir concurrency             (default nproc)
#   KEEP_RELEASES   releases to retain              (default 3)
#   PART_BYTES      bytes per published part        (default 134217728)
#   BUILD_ID        release id                      (default today, UTC)
#   PBF_NAME        source map file    (default us-latest.osm.pbf)
#   PBF_URL         where to fetch it  (default Geofabrik us-latest)
#   SKIP_PBF_UPDATE set to 1 to reuse the PBF on disk
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

BIN="$(dirname "${BASH_SOURCE[0]}")"
started="$(date -u +%s)"

status() {
  # Operator visibility while a multi-hour build runs. Served with no-store.
  mkdir -p "$DOCROOT/v1"
  local tmp="$DOCROOT/v1/.build-status.tmp"
  cat > "$tmp" <<EOF
{"build_id":"${BUILD_ID}","stage":"$1","detail":"${2:-}",
 "started_at":"$(date -u -d "@${started}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
 "updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  mv -f "$tmp" "$DOCROOT/v1/build-status.json"
}

fail() { status "failed" "$1"; die "$1"; }
trap 'status "failed" "aborted at line $LINENO"' ERR

log "=== FLCKD tile release ${BUILD_ID} ==="
log "threads=${THREADS} docroot=${DOCROOT} keep=${KEEP_RELEASES}"

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
OSM_DATE="$(date -u -r "$PBF" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
log "source PBF: $(human "$(stat -c %s "$PBF")"), dated ${OSM_DATE}"

# ---------------------------------------------------------------------------
status "build-graph" "national graph, the long stage"
THREADS="$THREADS" "$BIN/build-graph.sh"

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

# ---------------------------------------------------------------------------
# Push to R2 if configured. The local docroot stays authoritative either way,
# so a self-hosted nginx origin and an R2 front door can run side by side.
if [ -n "${R2_BUCKET:-}" ]; then
  status "push-r2"
  "$BIN/push-r2.sh" "$DOCROOT"
else
  log "R2_BUCKET unset - serving from the local docroot only"
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
status "done" "$(( elapsed / 60 )) min"
log "=== release ${BUILD_ID} complete in $(( elapsed / 60 )) min ==="
