#!/usr/bin/env python3
"""Convert Osmosis .poly boundary files to GeoJSON polygons.

`valhalla_build_extract -g <dir>` selects tiles by GeoJSON polygon, and
Geofabrik publishes a .poly for every region it offers, so no bounding box is
ever hand-written.

Format reference: https://wiki.openstreetmap.org/wiki/Osmosis/Polygon_Filter_File_Format

  <name>
  <ring name>              # a leading '!' means the ring is a hole
     <lon> <lat>
     ...
  END
  END

Usage:
  poly2geojson.py <in.poly> <out.geojson> [--id ID] [--name NAME]

Writes a GeoJSON Feature (Polygon or MultiPolygon) and prints the bbox as
JSON on stdout so callers can capture it without re-parsing.
"""
import argparse
import json
import sys


def parse_poly(text):
    """Return (outer_rings, inner_rings) as lists of [lon, lat] rings."""
    lines = text.splitlines()
    if not lines:
        raise ValueError("empty .poly file")

    outers, inners = [], []
    i = 1  # line 0 is the file name
    while i < len(lines):
        header = lines[i].strip()
        i += 1
        if header == "" :
            continue
        if header == "END":
            break
        is_hole = header.startswith("!")
        ring = []
        while i < len(lines):
            line = lines[i].strip()
            i += 1
            if line == "END":
                break
            if not line:
                continue
            parts = line.split()
            if len(parts) < 2:
                raise ValueError("bad coordinate line: %r" % line)
            lon, lat = float(parts[0]), float(parts[1])
            ring.append([lon, lat])
        if len(ring) < 3:
            raise ValueError("ring %r has fewer than 3 points" % header)
        # GeoJSON requires the ring to be explicitly closed.
        if ring[0] != ring[-1]:
            ring.append(ring[0])
        (inners if is_hole else outers).append(ring)

    if not outers:
        raise ValueError("no outer ring found")
    return outers, inners


def bbox_of(rings):
    xs = [p[0] for r in rings for p in r]
    ys = [p[1] for r in rings for p in r]
    return [min(xs), min(ys), max(xs), max(ys)]


def ring_contains_point(ring, pt):
    """Ray casting. Used only to attach holes to the right outer ring."""
    x, y = pt
    inside = False
    n = len(ring)
    for a in range(n - 1):
        x1, y1 = ring[a]
        x2, y2 = ring[a + 1]
        if (y1 > y) != (y2 > y):
            xin = (x2 - x1) * (y - y1) / (y2 - y1) + x1
            if x < xin:
                inside = not inside
    return inside


def build_geometry(outers, inners):
    if len(outers) == 1:
        holes = [h for h in inners]
        return {"type": "Polygon", "coordinates": [outers[0]] + holes}

    polys = []
    for outer in outers:
        holes = [h for h in inners if ring_contains_point(outer, h[0])]
        polys.append([outer] + holes)
    return {"type": "MultiPolygon", "coordinates": polys}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--id", default=None)
    ap.add_argument("--name", default=None)
    args = ap.parse_args()

    with open(args.infile, "r", encoding="utf-8") as fh:
        outers, inners = parse_poly(fh.read())

    bbox = bbox_of(outers)

    # The shape matters. valhalla_build_extract -g (3.6.3) does:
    #
    #     for file in input_dir.glob("*.geojson"):
    #         geojson = json.load(...)
    #         for feature in geojson["features"]:
    #             if feature["geometry"]["type"] == "Polygon":
    #                 polygons.append(Polygon(feature["geometry"]["coordinates"][0]))
    #
    # Consequences:
    #   1. The top level must be a FeatureCollection. A bare Feature or
    #      Geometry raises KeyError on "features".
    #   2. Only "Polygon" is picked up, so emit one Polygon feature per outer
    #      ring rather than a single MultiPolygon. A region with islands
    #      (Hawaii, Alaska, Michigan) contributes several features, which -g
    #      unions.
    #   3. Only coordinates[0] is read, so holes are discarded upstream. They
    #      are not emitted; a hole would only exclude tiles that are wanted.
    #      `inners` is still parsed and counted for the caller.
    #   4. The glob is "*.geojson"; a ".json" suffix is silently skipped.
    features = []
    for n, outer in enumerate(outers):
        features.append({
            "type": "Feature",
            "properties": {
                "id": args.id or "",
                "name": args.name or args.id or "",
                "part": n,
            },
            "geometry": {"type": "Polygon", "coordinates": [outer]},
        })

    collection = {
        "type": "FeatureCollection",
        "bbox": bbox,
        "features": features,
    }

    if not args.outfile.endswith(".geojson"):
        sys.stderr.write(
            "WARNING: %s does not end in .geojson - "
            "valhalla_build_extract -g will not see it\n" % args.outfile)

    with open(args.outfile, "w", encoding="utf-8") as fh:
        json.dump(collection, fh)
        fh.write("\n")

    json.dump({"id": args.id, "bbox": bbox, "features": len(features),
               "outer_rings": len(outers), "holes_dropped": len(inners)},
              sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
