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

Usage:
    publish.py --staging /data/staging \
               --docroot /srv/tiles \
               --regions /opt/flckd/regions/us-states.json \
               --build-id 2026-08-30 \
               [--part-bytes 134217728] [--keep 3] [--dry-run]
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--staging", required=True,
                    help="directory holding <region>.tar files from cut-packs.sh")
    ap.add_argument("--docroot", required=True,
                    help="nginx root; this script writes <docroot>/v1/...")
    ap.add_argument("--regions", required=True,
                    help="region set json (names, bboxes, iso codes)")
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

    staging = Path(args.staging)
    docroot = Path(args.docroot)
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

    # Immutable per-release copy first, then the mutable pointer. Order
    # matters: the pointer must never advertise something not yet on disk.
    release_manifest = docroot / "v1" / "releases" / args.build_id / "manifest.json"
    write_json_atomic(release_manifest, manifest, mtime=FIXED_MTIME)

    pointer = dict(manifest)
    pointer["release_manifest"] = "/v1/releases/%s/manifest.json" % args.build_id
    write_json_atomic(docroot / "v1" / "manifest.json", pointer,
                      mtime=int(time.time()))

    pruned = prune(docroot, args.keep)

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
