#!/usr/bin/env bash
# Clip the source map down to the regions being published.
#
# valhalla_build_tiles has no clipping flag and mjolnir has no bounding_box,
# so shrinking the source is the only way to make a small catalog a small
# build. It is worth doing because peak scratch is ~20x the PBF: one state is
# a few GB and minutes, where the national file is ~250 GB and hours.
#
# The clip carries a buffer, so roads do not stop dead at the border. Packs
# are cut on whole tiles and already reach past a region's edge; without the
# buffer those tiles would be cut from a graph that has nothing in them.
#
# Usage:  clip-pbf.sh <source.pbf> <region-id> [region-id ...]
#         prints the clipped PBF path on stdout; everything else goes to stderr
#   DATA_DIR         working dir      (default /data)
#   REGION_SET       region json      (default /opt/flckd/regions/us-states.json)
#   CLIP_BUFFER_DEG  border margin    (default 0.5, roughly 55 km)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DATA_DIR="${DATA_DIR:-/data}"
CLIP_BUFFER_DEG="${CLIP_BUFFER_DEG:-0.5}"

[ "$#" -ge 2 ] || die "usage: clip-pbf.sh <source.pbf> <region-id> [region-id ...]"
SRC="$1"; shift
[ -f "$SRC" ] || die "source PBF not found: $SRC"

need osmium
need python3
python3 -c "import shapely" 2>/dev/null \
  || die "python3-shapely missing - the clip boundary needs it"

OUT="${DATA_DIR}/clip.osm.pbf"
BOUNDARY="${DATA_DIR}/clip-boundary.geojson"

log "clipping $(basename "$SRC") to $# region(s) with a ${CLIP_BUFFER_DEG} degree margin"

shapes=()
for id in "$@"; do
  shapes+=("$(region_geojson "$id")")
done

# osmium --polygon reads one (multi)polygon, so the regions are merged into a
# single feature here rather than passed as a collection.
python3 - "$BOUNDARY" "$CLIP_BUFFER_DEG" "${shapes[@]}" <<'PY'
import json, sys
from shapely.geometry import shape, mapping
from shapely.ops import unary_union

out, buffer_deg = sys.argv[1], float(sys.argv[2])
geoms = []
for path in sys.argv[3:]:
    doc = json.load(open(path))
    if doc.get("type") == "FeatureCollection":
        geoms += [shape(f["geometry"]) for f in doc["features"]]
    elif doc.get("type") == "Feature":
        geoms.append(shape(doc["geometry"]))
    else:
        geoms.append(shape(doc))

merged = unary_union(geoms)
if buffer_deg > 0:
    merged = merged.buffer(buffer_deg)
json.dump({"type": "Feature", "properties": {}, "geometry": mapping(merged)},
          open(out, "w"))
print("clip boundary: %s, bounds %s" % (merged.geom_type, merged.bounds),
      file=sys.stderr)
PY

[ -s "$BOUNDARY" ] || die "could not build a clip boundary from the selected regions"

SRC_BYTES="$(stat -c %s "$SRC")"
require_free "$DATA_DIR" "$SRC_BYTES" "clipped copy of the source map"

rm -f "$OUT"
# complete_ways keeps every node of a way that reaches into the region, so
# ways crossing the boundary stay routable instead of ending mid-segment.
osmium extract --polygon "$BOUNDARY" --strategy complete_ways \
  --overwrite --output "$OUT" "$SRC" >&2

[ -s "$OUT" ] || die "osmium extract produced no output"
log "clipped: $(human "$SRC_BYTES") -> $(human "$(stat -c %s "$OUT")")"
printf '%s' "$OUT"
