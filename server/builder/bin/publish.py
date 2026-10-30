#!/usr/bin/env python3
"""Publish built Valhalla region tars into the nginx docroot.

Content-addressed and immutable
-------------------------------
Every byte a client downloads lives at a path derived from its own sha256:

    /v1/packs/<sha256-of-whole-tar>/part-0000.tar

Consequences:

  * A pack whose content did not change between builds keeps the same URL, so
    Cloudflare keeps serving it from cache and no user re-downloads it.
  * A pack that did change gets a new URL, so there is nothing to purge and no
    cache-staleness window. Invalidation is by naming, not by API call.
  * Only /v1/manifest.json is ever overwritten, so it is the only URL that
    needs a Cloudflare purge after a release.

Deterministic mtime
-------------------
nginx computes ETag as hex(mtime)-hex(size) and never hashes the body
(src/http/ngx_http_core_module.c, ngx_http_set_etag). Same bytes with a
different mtime produce a different ETag, which breaks If-None-Match
revalidation. Every immutable file is therefore stamped with a fixed mtime, so
identical content yields an identical ETag on any machine.

Do not hand-roll an ETag with add_header: nginx's If-None-Match check reads an
internal pointer that add_header does not set, so revalidation silently
returns the full body instead of 304.

Part size
---------
Cloudflare will not cache a single object above 512 MB on Free/Pro/Business.
Over-limit objects are not rejected; they are proxied to origin on every
request (CF-Cache-Status: BYPASS), which fails when the home origin is off.
128 MB parts stay inside the limit and are what the client reassembles.

Parts are named with a .tar extension on purpose: Cloudflare's default
cacheable-extension list includes .tar but not .part or .0007.

Speed cameras
-------------
The national speed-camera file from extract_cameras.py is published the same
way, at /v1/cameras/<sha256>.json, and listed under "speed_cameras" in the
manifest. It is one small file, so it is not split into parts.

A full release lists it in both the release manifest and the pointer.
--cameras-only refreshes just the pointer's entry and leaves the packs and
every release manifest alone; that is the daily job that keeps camera data
current between road builds. Unchanged camera data has the same sha256, so
its URL doesn't change and no client downloads it again.

Usage:
    publish.py --staging /data/staging \
               --docroot /srv/tiles \
               --regions /opt/flckd/regions/us-states.json \
               --build-id 2026-08-30 \
               [--cameras /data/speed-cameras.json] \
               [--part-bytes 134217728] [--keep 3] [--dry-run]

    publish.py --docroot /srv/tiles --build-id <job> \
               --cameras /data/speed-cameras.json --cameras-only
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time
from pathlib import Path

# Fixed mtime for every immutable artifact: 2020-09-13T12:26:40Z.
# Any constant works as long as it never varies.
FIXED_MTIME = 1600000000

READ_CHUNK = 4 * 1024 * 1024


def log(msg):
    print("[%s] %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg),
          file=sys.stderr)


def die(msg, code=3):
    log("FATAL: " + msg)
    sys.exit(code)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(READ_CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def assert_valhalla_extract(path):
    """A valhalla_build_extract tar has index.bin as its first member.

    The mobile reader mmaps the tar and seeks via that index. A plain
    `tar -czf` of the tile directory produces an unindexed archive that the
    reader cannot use, and it would fail at runtime rather than here.
    """
    try:
        with tarfile.open(path, "r:") as tf:
            first = tf.next()
    except tarfile.ReadError as exc:
        die("%s is not a readable uncompressed tar: %s" % (path.name, exc))
    if first is None:
        die("%s is an empty tar" % path.name)
    if first.name != "index.bin":
        die("%s is not a valhalla_build_extract tar: first tar member is %r, "
            "expected index.bin" % (path.name, first.name))


def stamp(path):
    os.utime(path, (FIXED_MTIME, FIXED_MTIME))


def split_pack(src, outdir, part_bytes):
    """Write src into outdir as part-NNNN.tar. Returns a list of part dicts."""
    outdir.mkdir(parents=True, exist_ok=True)
    parts = []
    idx = 0
    with open(src, "rb") as fh:
        while True:
            buf = fh.read(part_bytes)
            if not buf:
                break
            name = "part-%04d.tar" % idx
            dest = outdir / name
            tmp = outdir / (name + ".tmp")
            with open(tmp, "wb") as out:
                out.write(buf)
            os.replace(tmp, dest)
            stamp(dest)
            parts.append({
                "index": idx,
                "name": name,
                "bytes": len(buf),
                "sha256": hashlib.sha256(buf).hexdigest(),
            })
            idx += 1
    return parts


def write_json_atomic(path, obj, mtime=None, indent=2):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmpname = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=indent, sort_keys=False)
        fh.write("\n")
    if mtime is not None:
        os.utime(tmpname, (mtime, mtime))
    os.replace(tmpname, path)


def load_regions(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return {p["id"]: p for p in data["packs"]}


def publish_cameras(src, docroot, build_id):
    """Copy the camera file to its content-addressed path. Returns the
    manifest entry."""
    data = Path(src).read_bytes()
    try:
        doc = json.loads(data)
    except ValueError as exc:
        die("%s is not valid JSON: %s" % (src, exc))
    if not isinstance(doc.get("cameras"), list):
        die("%s has no cameras list" % src)

    digest = hashlib.sha256(data).hexdigest()
    root = docroot / "v1" / "cameras"
    root.mkdir(parents=True, exist_ok=True)
    dest = root / (digest + ".json")
    if not dest.is_file():
        tmp = root / (digest + ".json.tmp")
        tmp.write_bytes(data)
        os.replace(tmp, dest)
    stamp(dest)
    log("speed cameras: %d in %s" % (len(doc["cameras"]), human(len(data))))
    return {
        "path": "/v1/cameras/%s.json" % digest,
        "bytes": len(data),
        "sha256": digest,
        "count": len(doc["cameras"]),
        "osm_data_date": doc.get("osm_data_date"),
        "license": doc.get("license"),
        "build_id": build_id,
    }


def camera_path(manifest):
    entry = manifest.get("speed_cameras") if isinstance(manifest, dict) else None
    return entry.get("path") if isinstance(entry, dict) else None


def read_pointer(docroot):
    try:
        return json.loads((docroot / "v1" / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def prune_cameras(docroot, keep):
    """Delete camera files that neither pointer (old or new) nor any retained
    release references. The previous pointer's file is kept because a client
    may have fetched that pointer moments ago and not the file yet."""
    root = docroot / "v1" / "cameras"
    if not root.is_dir():
        return
    keep = {p for p in keep if p}
    rel_root = docroot / "v1" / "releases"
    if rel_root.is_dir():
        for mf in rel_root.glob("*/manifest.json"):
            try:
                keep.add(camera_path(json.loads(mf.read_text(encoding="utf-8"))))
            except (OSError, ValueError):
                log("WARNING: %s unreadable; not pruning camera files this run" % mf)
                return
    for f in root.iterdir():
        if "/v1/cameras/%s" % f.name not in keep:
            f.unlink()
            log("pruned camera file %s" % f.name[:12])


def publish_cameras_only(args, docroot):
    pointer = read_pointer(docroot)
    if pointer is None:
        die("no published release at %s/v1/manifest.json to attach speed cameras "
            "to; run a full build first" % docroot)
    previous = camera_path(pointer)
    entry = publish_cameras(args.cameras, docroot, args.build_id)
    pointer["speed_cameras"] = entry
    write_json_atomic(docroot / "v1" / "manifest.json", pointer, mtime=int(time.time()))
    prune_cameras(docroot, {entry["path"], previous})
    unchanged = entry["path"] == previous
    log("speed cameras %s at %s" % ("unchanged" if unchanged else "updated", entry["path"]))
    print(json.dumps({"build_id": args.build_id, "speed_cameras": entry,
                      "unchanged": unchanged}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--staging",
                    help="directory holding <region>.tar files from cut-packs.sh")
    ap.add_argument("--docroot", required=True,
                    help="nginx root; this script writes <docroot>/v1/...")
    ap.add_argument("--regions",
                    help="region set json (names, bboxes, iso codes)")
    ap.add_argument("--cameras",
                    help="speed-camera JSON from extract_cameras.py")
    ap.add_argument("--cameras-only", action="store_true",
                    help="publish only --cameras, into the current pointer")
    ap.add_argument("--build-id", required=True,
                    help="release id, e.g. 2026-08-30")
    ap.add_argument("--part-bytes", type=int, default=128 * 1024 * 1024,
                    help="bytes per part (default 128 MiB; keep under 512 MB)")
    ap.add_argument("--keep", type=int, default=3,
                    help="how many releases to retain (default 3)")
    ap.add_argument("--valhalla-version", default="3.6.3")
    ap.add_argument("--osm-data-date", default=None,
                    help="date of the source PBF, for the client to display")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    docroot = Path(args.docroot)
    if args.cameras_only:
        if not args.cameras:
            die("--cameras-only needs --cameras")
        publish_cameras_only(args, docroot)
        return
    if not args.staging or not args.regions:
        die("--staging and --regions are required for a release")

    staging = Path(args.staging)
    regions = load_regions(args.regions)

    if args.part_bytes and args.part_bytes > 500 * 1000 * 1000:
        die("--part-bytes %d exceeds Cloudflare's 512 MB cacheable object "
            "limit; such objects are proxied uncached on every request"
            % args.part_bytes)

    tars = sorted(staging.glob("*.tar"))
    if not tars:
        die("no *.tar found in %s" % staging)
    log("found %d pack tars in staging" % len(tars))

    # Validate everything before publishing anything: the pointer must never
    # advertise a half-published release.
    for t in tars:
        rid = t.stem
        if rid not in regions:
            die("%s has no entry in %s" % (t.name, args.regions))
        assert_valhalla_extract(t)
    log("all %d tars verified: first member is index.bin" % len(tars))

    if args.dry_run:
        total = sum(t.stat().st_size for t in tars)
        print(json.dumps({"dry_run": True, "packs": len(tars),
                          "total_bytes": total}))
        return

    packs_root = docroot / "v1" / "packs"
    packs_root.mkdir(parents=True, exist_ok=True)

    entries = []
    total_bytes = 0
    reused = 0
    for t in tars:
        rid = t.stem
        meta = regions[rid]
        size = t.stat().st_size
        digest = sha256_file(t)
        total_bytes += size

        packdir = packs_root / digest
        marker = packdir / "COMPLETE"

        if marker.is_file():
            # Same bytes as a previous build. The URL is unchanged, so every
            # edge cache and every already-downloaded client stays valid.
            parts = json.loads(marker.read_text(encoding="utf-8"))
            reused += 1
            log("reusing %s (%s, unchanged since a previous build)"
                % (rid, human(size)))
        else:
            log("publishing %s (%s)" % (rid, human(size)))
            tmpdir = packdir.with_name(digest + ".incoming")
            if tmpdir.exists():
                shutil.rmtree(tmpdir)
            parts = split_pack(t, tmpdir, args.part_bytes or size)
            write_json_atomic(tmpdir / "COMPLETE", parts, mtime=FIXED_MTIME)
            os.replace(tmpdir, packdir)
            stamp(packdir)

        entries.append({
            "id": rid,
            "name": meta.get("name", rid),
            "iso3166_2": meta.get("iso3166_2"),
            "bbox": meta.get("bbox"),
            "bytes": size,
            "sha256": digest,
            "part_bytes": args.part_bytes or size,
            "parts": [{
                "index": p["index"],
                "path": "/v1/packs/%s/%s" % (digest, p["name"]),
                "bytes": p["bytes"],
                "sha256": p["sha256"],
            } for p in parts],
        })

    entries.sort(key=lambda e: e["id"])

    manifest = {
        "schema": 1,
        "build_id": args.build_id,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "valhalla_version": args.valhalla_version,
        "osm_data_date": args.osm_data_date,
        "total_bytes": total_bytes,
        "packs": entries,
    }
    if args.cameras:
        manifest["speed_cameras"] = publish_cameras(args.cameras, docroot, args.build_id)
    previous_cameras = camera_path(read_pointer(docroot))

    # Immutable per-release copy first, then the mutable pointer. Order
    # matters: the pointer must never advertise something not yet on disk.
    release_manifest = docroot / "v1" / "releases" / args.build_id / "manifest.json"
    write_json_atomic(release_manifest, manifest, mtime=FIXED_MTIME)

    pointer = dict(manifest)
    pointer["release_manifest"] = "/v1/releases/%s/manifest.json" % args.build_id
    write_json_atomic(docroot / "v1" / "manifest.json", pointer,
                      mtime=int(time.time()))

    pruned = prune(docroot, args.keep)
    prune_cameras(docroot, {camera_path(pointer), previous_cameras})

    write_json_atomic(docroot / "v1" / "build-status.json", {
        "build_id": args.build_id,
        "published_at": manifest["generated_at"],
        "packs": len(entries),
        "reused_packs": reused,
        "total_bytes": total_bytes,
    }, mtime=int(time.time()))

    log("published build %s: %d packs (%d unchanged), %.2f GB, pruned %d old "
        "release(s)" % (args.build_id, len(entries), reused,
                        total_bytes / 1e9, len(pruned)))
    print(json.dumps({"build_id": args.build_id, "packs": len(entries),
                      "reused_packs": reused, "total_bytes": total_bytes,
                      "pruned": pruned}))


def prune(docroot, keep):
    """Drop old releases, then delete pack blobs nothing references any more.

    Pack directories are shared between releases, so they can only be removed
    by reference counting, never by age.
    """
    rel_root = docroot / "v1" / "releases"
    if not rel_root.is_dir():
        return []
    releases = sorted(p.name for p in rel_root.iterdir() if p.is_dir())
    doomed = releases[:-keep] if keep > 0 and len(releases) > keep else []
    for r in doomed:
        shutil.rmtree(rel_root / r)
        log("pruned release %s" % r)

    # A retained release whose manifest cannot be read still references
    # blobs; deleting "orphans" without knowing which ones would break it.
    # In that case leave every blob alone.
    referenced = set()
    unreadable = []
    for r in sorted(p.name for p in rel_root.iterdir() if p.is_dir()):
        mf = rel_root / r / "manifest.json"
        try:
            data = json.loads(mf.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            unreadable.append(r)
            continue
        for p in data.get("packs", []):
            if p.get("sha256"):
                referenced.add(p["sha256"])

    packs_root = docroot / "v1" / "packs"
    if not packs_root.is_dir():
        return doomed
    for d in packs_root.iterdir():
        if d.is_dir() and d.name.endswith(".incoming"):
            shutil.rmtree(d)
    if unreadable:
        log("WARNING: release manifest(s) unreadable: %s; not pruning any pack "
            "blobs this run" % ", ".join(unreadable))
        return doomed
    for d in packs_root.iterdir():
        if d.is_dir() and d.name not in referenced:
            shutil.rmtree(d)
            log("pruned orphaned pack blob %s" % d.name[:12])
    return doomed


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0


if __name__ == "__main__":
    main()
