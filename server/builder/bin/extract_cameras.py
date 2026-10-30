#!/usr/bin/env python3
"""Extract every speed and red-light camera in a PBF into one JSON file.

The app downloads this file with a region pack, so it never has to ask a
live server for the cameras around the user. Everyone gets the same bytes,
so the download says nothing about where anyone is.

OpenStreetMap maps these cameras two ways, and several hundred US cameras
exist only in the second:

  * a node tagged highway=speed_camera, or a bare node with enforcement=*
  * a type=enforcement relation, whose "device" member is the camera and
    whose "from" member is where enforcement starts

Only maxspeed, average_speed and traffic_signals enforcement count. The
other values (check, toll, maxweight, ...) are checkpoints and scales, not
cameras a driver is warned about.

A relation whose device node is itself a highway=speed_camera node would
otherwise appear twice; the node wins. Relations get negative ids so they
can't collide with a node of the same number (the app does the same).

The output has no timestamp and is sorted, so unchanged map data produces
identical bytes, the same sha256 and therefore the same published URL.

Usage:
    extract_cameras.py --pbf us-latest.osm.pbf --out speed-cameras.json \
                       [--osm-data-date 2026-10-28]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CAMERA_ENFORCEMENT = {"maxspeed", "average_speed", "traffic_signals"}

# osmium tags-filter keeps the objects these match plus everything they
# reference, so a relation arrives with its member nodes.
FILTERS = ["n/highway=speed_camera", "n/enforcement", "r/type=enforcement"]

LICENSE = "ODbL-1.0"
ATTRIBUTION = "© OpenStreetMap contributors"


def log(msg):
    print("[%s] %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg),
          file=sys.stderr)


def die(msg):
    log("FATAL: " + msg)
    fatal = os.environ.get("FATAL_FILE")
    if fatal:
        try:
            Path(fatal).write_text(msg, encoding="utf-8")
        except OSError:
            pass
    sys.exit(1)


def enforces_camera(value):
    return any(part.strip() in CAMERA_ENFORCEMENT for part in (value or "").split(";"))


def is_camera_node(tags):
    return tags.get("highway") == "speed_camera" or enforces_camera(tags.get("enforcement"))


def is_camera_relation(tags):
    return tags.get("type") == "enforcement" and enforces_camera(tags.get("enforcement"))


def record(osm_id, lat, lon, tags):
    return {
        "id": osm_id,
        "lat": round(lat, 7),
        "lon": round(lon, 7),
        "tags": dict(sorted(tags.items())),
    }


def build_cameras(nodes, relations):
    """Cameras from already-read OSM data.

    nodes:     {node_id: (lat, lon, {tags})}, including untagged member nodes
    relations: [(relation_id, {tags}, [(member_type, ref, role), ...])]
    """
    cameras = {}
    camera_nodes = set()
    for nid, (lat, lon, tags) in nodes.items():
        if is_camera_node(tags):
            camera_nodes.add(nid)
            cameras[nid] = record(nid, lat, lon, tags)

    for rid, tags, members in relations:
        if not is_camera_relation(tags):
            continue
        located = [(ref, role) for kind, ref, role in members if kind == "n" and ref in nodes]
        devices = [ref for ref, role in located if role == "device"]
        if any(ref in camera_nodes for ref in devices):
            continue
        starts = [ref for ref, role in located if role == "from"]
        anchor = (devices or starts or [ref for ref, _ in located] or [None])[0]
        if anchor is None:
            continue
        lat, lon, _ = nodes[anchor]
        cameras[-rid] = record(-rid, lat, lon, tags)

    return [cameras[key] for key in sorted(cameras)]


def render(cameras, osm_data_date):
    """The published bytes. Compact and key-sorted so they are reproducible."""
    doc = {
        "schema": 1,
        "osm_data_date": osm_data_date,
        "license": LICENSE,
        "attribution": ATTRIBUTION,
        "count": len(cameras),
        "cameras": cameras,
    }
    return (json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            + "\n").encode("utf-8")


def read_pbf(path):
    import osmium  # only in the builder image; the pure functions above don't need it

    class Reader(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.nodes = {}
            self.relations = []

        def node(self, n):
            if n.location.valid():
                self.nodes[n.id] = (n.location.lat, n.location.lon,
                                    {t.k: t.v for t in n.tags})

        def relation(self, r):
            self.relations.append((r.id, {t.k: t.v for t in r.tags},
                                   [(m.type, m.ref, m.role) for m in r.members]))

    reader = Reader()
    reader.apply_file(str(path))
    return reader.nodes, reader.relations


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pbf", required=True, help="source map, e.g. us-latest.osm.pbf")
    ap.add_argument("--out", required=True, help="where to write the camera JSON")
    ap.add_argument("--osm-data-date", default=None,
                    help="date of the source map, shown to the user")
    args = ap.parse_args()

    pbf = Path(args.pbf)
    out = Path(args.out)
    if not pbf.is_file():
        die("no source map at %s" % pbf)
    out.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(dir=str(out.parent)) as scratch:
        filtered = Path(scratch) / "cameras.osm.pbf"
        log("filtering %s for speed and red-light cameras" % pbf.name)
        try:
            subprocess.run(["osmium", "tags-filter", "--overwrite", "--no-progress",
                            "-o", str(filtered), str(pbf), *FILTERS], check=True)
        except (OSError, subprocess.CalledProcessError) as exc:
            die("osmium tags-filter failed: %s" % exc)
        nodes, relations = read_pbf(filtered)

    cameras = build_cameras(nodes, relations)
    from_relations = sum(1 for c in cameras if c["id"] < 0)
    if not cameras:
        log("WARNING: no speed cameras in %s; publishing an empty file" % pbf.name)

    data = render(cameras, args.osm_data_date)
    fd, tmp = tempfile.mkstemp(dir=str(out.parent), suffix=".tmp")
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    os.replace(tmp, out)
    log("wrote %d cameras (%d from enforcement relations), %d bytes, to %s"
        % (len(cameras), from_relations, len(data), out))


if __name__ == "__main__":
    main()
