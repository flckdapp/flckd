#!/usr/bin/env bash
# Keep the national PBF current using Geofabrik's daily replication diffs.
#
# us-latest.osm.pbf is ~12 GB; the daily diffs are ~10.5 MB/day (~321 MB per
# month), so applying diffs beats re-downloading every month.
#
# Geofabrik keeps diffs for 100 days. If the local PBF is 90 or more days
# behind, the script re-seeds with a full download instead.
#
# Usage:  update-pbf.sh [--reseed]
#   DATA_DIR  where the PBF lives          (default /data)
#   PBF_NAME  file name                    (default us-latest.osm.pbf)
#   PBF_URL   full-download URL for reseed

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DATA_DIR="${DATA_DIR:-/data}"
PBF_NAME="${PBF_NAME:-us-latest.osm.pbf}"
PBF_URL="${PBF_URL:-https://download.geofabrik.de/north-america/us-latest.osm.pbf}"
PBF="${DATA_DIR}/${PBF_NAME}"

RESEED=0
[ "${1:-}" = "--reseed" ] && RESEED=1

need pyosmium-up-to-date
need osmium

mkdir -p "$DATA_DIR"

reseed() {
  log "seeding full PBF from $PBF_URL (this is ~12 GB for the US)"
  require_free "$DATA_DIR" $((26 * 1024 ** 3)) "full PBF download + osmium rewrite headroom"
  fetch_verified "$PBF_URL" "${PBF}.tmp"
  mv "${PBF}.tmp" "$PBF"
  log "seeded $(human "$(stat -c %s "$PBF")")"
}

if [ ! -f "$PBF" ] || [ "$RESEED" = 1 ]; then
  reseed
else
  # How stale is the local file? osmium fileinfo reads the replication headers
  # that Geofabrik stamps into the PBF.
  ts="$(osmium fileinfo -e -g header.option.osmosis_replication_timestamp "$PBF" 2>/dev/null || true)"
  if [ -n "$ts" ]; then
    log "local PBF replication timestamp: $ts"
    now_s=$(date -u +%s)
    then_s=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    if [ "$then_s" -gt 0 ]; then
      age_days=$(( (now_s - then_s) / 86400 ))
      log "local PBF is ${age_days} day(s) behind"
      if [ "$age_days" -ge 90 ]; then
        log "WARNING: ${age_days} days old. Geofabrik prunes diffs at 100 days."
        log "Re-seeding with a full download instead of chasing diffs."
        reseed
      fi
    fi
  else
    log "WARNING: no replication headers in $PBF - cannot apply diffs, re-seeding"
    reseed
  fi
fi

# pyosmium-up-to-date rewrites the file in place via a temp copy, so budget
# for a second copy of the PBF.
sz="$(stat -c %s "$PBF")"
require_free "$DATA_DIR" $(( sz * 2 + 2 * 1024 ** 3 )) "in-place PBF update (needs a second copy)"

log "applying replication diffs..."
# Exit 0 = fully up to date. Exit 1 = applied some, more remain (size cap hit).
# Loop until it reports 0. --size is in MB of change data per pass.
for attempt in $(seq 1 20); do
  set +e
  # pyosmium 3.7.0 (Ubuntu 24.04) only accepts -v, not --verbose.
  pyosmium-up-to-date --size 2000 -v "$PBF"
  rc=$?
  set -e
  case "$rc" in
    0) log "PBF fully up to date"; break ;;
    1) log "pass ${attempt}: partial update applied, continuing" ;;
    *)
      # Server or network error (Geofabrik backends are sometimes partially
      # down). The tool rewrites via a temp copy, so $PBF is intact. It is
      # under 90 days old or freshly seeded, and a slightly stale build beats
      # no build, so warn and continue.
      log "WARNING: pyosmium-up-to-date failed with exit $rc (Geofabrik unreachable?)"
      log "WARNING: continuing with existing PBF as-is"
      break ;;
  esac
done

osmium fileinfo -e "$PBF" | sed 's/^/  /' >&2
log "done: $PBF ($(human "$(stat -c %s "$PBF")"))"
