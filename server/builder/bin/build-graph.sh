#!/usr/bin/env bash
# Build the Valhalla routing graph for a source PBF.
#
# This is the expensive step. Run it once for the whole US, then cut per-region
# tars out of the result with cut-packs.sh.
#
# Stage order is from upstream docs/start/building.md and
# docker/scripts/configure_valhalla.sh. Two traps:
#   - valhalla_build_timezones writes the sqlite to stdout; redirect it.
#   - valhalla_build_extract takes no positional path args; it reads
#     mjolnir.tile_dir and mjolnir.tile_extract from the config.
#
# Usage:  build-graph.sh
#   DATA_DIR     working dir                 (default /data)
#   PBF_NAME     input PBF                   (default us-latest.osm.pbf)
#   THREADS      mjolnir concurrency         (default nproc)
#   MAX_CACHE_MB per-thread tile cache       (default 700)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

GRAPH_STEPS=5
step() {
  log "stage $1/${GRAPH_STEPS}: $2"
  progress "$(( $1 - 1 ))" "$GRAPH_STEPS" "step $1 of ${GRAPH_STEPS}: $2"
}

DATA_DIR="${DATA_DIR:-/data}"
PBF_NAME="${PBF_NAME:-us-latest.osm.pbf}"
THREADS="${THREADS:-$(nproc)}"
MAX_CACHE_MB="${MAX_CACHE_MB:-700}"

PBF="${DATA_DIR}/${PBF_NAME}"
GRAPH_DIR="${DATA_DIR}/graph"
TILE_DIR="${GRAPH_DIR}/valhalla_tiles"
CONFIG="${GRAPH_DIR}/valhalla.json"
FULL_TAR="${GRAPH_DIR}/valhalla_tiles.tar"

need valhalla_build_config
need valhalla_build_tiles
[ -f "$PBF" ] || die "input PBF not found: $PBF"

PBF_BYTES="$(stat -c %s "$PBF")"

# Peak scratch is the binding constraint, not the final artifact.
# valhalla_build_tiles writes ways.bin / way_nodes.bin / nodes.bin inside
# mjolnir.tile_dir; there is no temp-dir option. A planet build reported
# 1.2 TB of .bin from a ~74 GB PBF (valhalla#4548), about 16x. Budget 20x.
require_free "$DATA_DIR" $(( PBF_BYTES * 20 )) "build scratch (.bin intermediates are ~16-20x the PBF)"

# Peak RAM tracks thread count, not region size: mjolnir.max_cache_size is
# per thread. Measured (valhalla#4689, 4 US states): 8 threads = 14.0 GiB RSS,
# 2 threads = 4.65 GiB. Roughly 1.55 GB/thread + 1.5 GB base.
est_ram_gb=$(awk -v t="$THREADS" 'BEGIN{printf "%.1f", t*1.55 + 1.5}')
log "concurrency=${THREADS} -> estimated peak RSS ~${est_ram_gb} GiB"
log "if the build is OOM-killed, lower THREADS. It is the memory dial."

mkdir -p "$TILE_DIR"

step 1 "config"
valhalla_build_config \
  --mjolnir-tile-dir       "$TILE_DIR" \
  --mjolnir-tile-extract   "$FULL_TAR" \
  --mjolnir-timezone       "${GRAPH_DIR}/timezones.sqlite" \
  --mjolnir-admin          "${GRAPH_DIR}/admins.sqlite" \
  --mjolnir-concurrency    "$THREADS" \
  > "$CONFIG"

# Post-process the config rather than trust extra generator flags.
#
#   tile_url         -> "" so a reader built from this config can never fetch
#                       tiles over HTTP (graphreader.cc:522 skips the HTTP
#                       getter when tile_url is empty). Privacy guarantee.
#   concurrency      -> absent from the stock config (optional in the schema),
#                       so anything reading config["mjolnir"]["concurrency"]
#                       raises KeyError. Set it explicitly.
#   max_cache_size   -> per thread; the stock default is 1 GB, which is why an
#                       8-thread build peaks near 14 GiB.
python3 - "$CONFIG" "$THREADS" "$MAX_CACHE_MB" <<'PY'
import json, sys
p, threads, cache_mb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
c = json.load(open(p))
m = c.setdefault("mjolnir", {})
m["tile_url"] = ""
m["concurrency"] = threads
m["max_cache_size"] = cache_mb * 1024 * 1024
json.dump(c, open(p, "w"), indent=2)
print(f"config: tile_url='' concurrency={threads} "
      f"max_cache_size={cache_mb}MB/thread", file=sys.stderr)
PY

# valhalla_build_timezones is a POSIX sh script with no argument parsing
# ("--help" would run a full build). It writes the sqlite to stdout and logs
# to stderr, so the redirect is mandatory.
#
# It needs network access at run time. It downloads a hardcoded release:
#   github.com/evansiroky/timezone-boundary-builder/releases/download/2025b/
#   timezones-with-oceans-1970.shapefile.zip
# Without network it exits 1 and leaves a 0-byte file. If the build host is
# firewalled, allow github.com + objects.githubusercontent.com, or pre-stage
# the sqlite and set SKIP_TIMEZONES=1.
#
# pkg-config is missing from the base image, so the script's own error_exit
# guard can fall through and exit 0 with junk. Check the output, not just $?.
TZ_DB="${GRAPH_DIR}/timezones.sqlite"
TZ_MIN_BYTES=1000000   # real db is tens of MB; anything smaller is a failure

step 2 "timezones (writes sqlite to stdout - redirected)"
if [ "${SKIP_TIMEZONES:-0}" = "1" ]; then
  [ -s "$TZ_DB" ] || die "SKIP_TIMEZONES=1 but no pre-staged $TZ_DB"
  log "SKIP_TIMEZONES=1, using pre-staged $TZ_DB"
elif [ -s "$TZ_DB" ] && [ "$(stat -c %s "$TZ_DB")" -ge "$TZ_MIN_BYTES" ]; then
  log "timezones.sqlite already present ($(human "$(stat -c %s "$TZ_DB")")), skipping"
else
  rm -f "$TZ_DB"
  valhalla_build_timezones > "$TZ_DB" || die \
    "valhalla_build_timezones failed - it downloads from github.com at run time, check network"
  tz_bytes="$(stat -c %s "$TZ_DB" 2>/dev/null || echo 0)"
  [ "$tz_bytes" -ge "$TZ_MIN_BYTES" ] || die \
    "timezones.sqlite is only $(human "$tz_bytes") - the github.com download almost certainly failed"
  head -c 15 "$TZ_DB" | grep -q "SQLite format 3" || die \
    "timezones.sqlite is not a SQLite database - download produced junk"
  log "timezones.sqlite OK ($(human "$tz_bytes"))"
fi

step 3 "admins (driving side, country access, border penalties)"
valhalla_build_admins -c "$CONFIG" "$PBF"

step 4 "tiles - this is the long one"
time valhalla_build_tiles -c "$CONFIG" "$PBF"

# Do not add -e/--extract-tar here. It is not an output-path flag: it switches
# the input from mjolnir.tile_dir to the tar at mjolnir.tile_extract. With -e
# absent, the output path is taken from mjolnir.tile_extract in the config.
step 5 "pack to an indexed tar for mmap"
rm -f "$FULL_TAR"
valhalla_build_extract -c "$CONFIG" -O -v

progress "$GRAPH_STEPS" "$GRAPH_STEPS" "graph complete"
[ -s "$FULL_TAR" ] || die "valhalla_build_extract produced no tar"
log "full graph tar: $FULL_TAR ($(human "$(stat -c %s "$FULL_TAR")"))"
log "tile dir retained at $TILE_DIR - cut-packs.sh needs it"
