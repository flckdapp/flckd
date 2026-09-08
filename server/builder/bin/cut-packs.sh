#!/usr/bin/env bash
# Cut per-region tile tars out of the one national graph.
#
# There is no mjolnir.bounding_box, so the build cannot be limited to a bbox.
# Cut afterwards with valhalla_build_extract -b (bbox) or -g (geojson dir).
# Both exist in 3.6.3 and are mutually exclusive. -r/--region (Geofabrik
# region name) was added in 3.7.0 and is not available on the 3.6.3 pin.
#
# One invocation per region. In 3.6.3, -g globs *.geojson in the directory,
# flattens every Polygon into one list, and writes one tar. Pointing it at a
# directory of every state would produce a single tar of their union, so each
# pass sees a directory holding only that region's geojson.
#
# -e/--extract-tar is not passed. It is not an output-path flag: it also
# switches the input from mjolnir.tile_dir to the tar at mjolnir.tile_extract.
# The output path comes from mjolnir.tile_extract, rewritten per region.
#
# Granularity is a whole tile: level 0 = 4 deg, level 1 = 1 deg, level 2 =
# 0.25 deg. Regions come out slightly larger than their border, which avoids
# severed routes at the edge.
#
# Usage:  cut-packs.sh [region-id ...]      (default: every region in the set)
#   DATA_DIR    working dir             (default /data)
#   REGION_SET  region json             (default /opt/flckd/regions/us-states.json)
#   STAGING     where tars land         (default /data/staging)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DATA_DIR="${DATA_DIR:-/data}"
REGION_SET="${REGION_SET:-/opt/flckd/regions/us-states.json}"
STAGING="${STAGING:-${DATA_DIR}/staging}"
GRAPH_DIR="${DATA_DIR}/graph"
CONFIG="${GRAPH_DIR}/valhalla.json"
TILE_DIR="${GRAPH_DIR}/valhalla_tiles"

need valhalla_build_extract
need python3
[ -f "$CONFIG" ]      || die "no config at $CONFIG - run build-graph.sh first"
[ -d "$TILE_DIR" ]    || die "no tile dir at $TILE_DIR - run build-graph.sh first"
[ -f "$REGION_SET" ]  || die "no region set at $REGION_SET"

# -g imports shapely lazily; fail now rather than deep inside the cut loop.
python3 -c "import shapely" 2>/dev/null \
  || die "python3-shapely missing - valhalla_build_extract -g needs it"

mkdir -p "$STAGING"

# Region ids from argv, else every pack in the set.
if [ "$#" -gt 0 ]; then
  ids=("$@")
else
  mapfile -t ids < <(python3 -c '
import json,sys
for p in json.load(open(sys.argv[1]))["packs"]: print(p["id"])' "$REGION_SET")
fi
log "cutting ${#ids[@]} region pack(s)"

failed=()
cut_done=0
for id in "${ids[@]}"; do
  progress "$cut_done" "${#ids[@]}" "cutting ${id} (${cut_done} of ${#ids[@]} regions done)"
  # Counted here, not at the end of the body: several paths `continue` on failure.
  cut_done=$((cut_done + 1))
  gj="$(region_geojson "$id")"

  workdir="$(mktemp -d "${DATA_DIR}/cut-XXXXXX")"
  mkdir -p "${workdir}/regions"
  # Extension must be .geojson: the glob is "*.geojson", so .json is skipped.
  cp "$gj" "${workdir}/regions/${id}.geojson"

  out="${STAGING}/${id}.tar"
  log "cutting ${id} -> ${out}"

  # Per-region output goes in the config. tile_dir stays pointing at the built
  # tiles so they remain the input.
  cfg="${workdir}/valhalla.json"
  python3 - "$CONFIG" "$cfg" "$out" "$TILE_DIR" <<'PY'
import json, sys
src, dst, out, tile_dir = sys.argv[1:5]
c = json.load(open(src))
c.setdefault("mjolnir", {})
c["mjolnir"]["tile_extract"] = out
c["mjolnir"]["tile_dir"] = tile_dir
json.dump(c, open(dst, "w"), indent=2)
PY

  rm -f "$out"
  # -O overwrite, -v verbosity counter (not --verbose; -v INFO, -vv DEBUG).
  if ! valhalla_build_extract -c "$cfg" -g "${workdir}/regions" -O -v; then
    log "  ${id}: BUILD_EXTRACT FAILED"
    failed+=("$id"); rm -rf "$workdir"; continue
  fi

  if [ ! -s "$out" ]; then
    log "  ${id}: no tar produced"
    failed+=("$id"); rm -rf "$workdir"; continue
  fi

  # The mobile reader mmaps this tar and needs index.bin as the first member.
  # awk 'NR==1' rather than head -1: head exits after one line, GNU tar dies
  # with SIGPIPE (exit 141), and pipefail would abort the build.
  first="$(tar -tf "$out" | awk 'NR==1')"
  if [ "$first" != "index.bin" ]; then
    log "  ${id}: first tar member is '$first', expected index.bin"
    failed+=("$id"); rm -rf "$workdir"; continue
  fi

  log "  ${id}: $(human "$(stat -c %s "$out")") OK"
  rm -rf "$workdir"
done

# find, not ls: an unmatched glob makes ls exit non-zero, and the status of a
# bare assignment is the substitution's, so set -e would abort here.
staged="$(find "$STAGING" -maxdepth 1 -name '*.tar' | wc -l | tr -d ' ')"
progress "${#ids[@]}" "${#ids[@]}" "cut ${staged} of ${#ids[@]} region pack(s)"
log "staged ${staged} tar(s) in $STAGING"

# A region the source map never contained cannot be cut, and that is the same
# non-zero exit as a real crash. Losing every other region's work to it is the
# worse error, so the release goes out with what was cut and names what wasn't.
if [ "${#failed[@]}" -gt 0 ]; then
  log "WARNING: ${#failed[@]} region(s) could not be cut: ${failed[*]}"
  log "WARNING: a region absent from the source map cannot be cut from it."
  log "WARNING: they are left out of this release; see server/README.md."
  [ -z "${SKIPPED_FILE:-}" ] || printf '%s' "${failed[*]}" > "$SKIPPED_FILE" 2>/dev/null || true
  [ "${STRICT_REGIONS:-0}" != "1" ] || die "${#failed[@]} region(s) failed: ${failed[*]}"
fi
[ "$staged" -gt 0 ] || die "no region packs were cut"
