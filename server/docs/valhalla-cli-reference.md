# Valhalla 3.6.3 command-line notes

What the Valhalla tools in the pinned image actually do, with the places
where the upstream documentation or the obvious assumption is wrong. Checked
against `ghcr.io/valhalla/valhalla:3.6.3` (`linux/arm64`, 2026-08-30) by
reading each tool's `--help` output and, where that wasn't enough, the tool's
source inside the image. A verbatim capture of that session, including the
full `--help` text and the complete default config JSON, is kept locally in
`ai-docs/` and isn't tracked.

Why 3.6.3: the iOS package `valhalla-mobile` 0.6.3 embeds Valhalla 3.6.3, and
tiles are memory-mapped binary structures, so the builder must match the
reader exactly. `server/builder/Dockerfile` starts `FROM` this image.

---

## The tools

| Tool | What it does | Notes |
|---|---|---|
| `valhalla_build_config` | Prints a full config JSON to stdout | Every config key is also a `--section-key` flag |
| `valhalla_build_admins` | Builds the admin SQLite database from PBF files | PBFs are trailing positional arguments; several allowed |
| `valhalla_build_timezones` | Builds the timezone SQLite database | Shell script; see below, it bites |
| `valhalla_build_tiles` | Builds the routing graph from PBF files | PBFs are trailing positionals; no spatial limiting |
| `valhalla_build_extract` | Packs tiles into a tar, optionally a spatial subset | Python; the `-e` flag isn't what it looks like |
| `valhalla_service` | Runs the HTTP service | `--help` lists only `-h` and `-v`; everything is in the config |

---

## `valhalla_build_tiles`

Seven flags and nothing else:

```
-c, --config arg         Path to the configuration file
-i, --inline-config arg  Inline JSON config
-s, --start arg          Starting stage of the build pipeline (default: initialize)
-e, --end arg            End stage of the build pipeline (default: cleanup)
-j, --concurrency arg    Number of threads to use. Defaults to all threads.
-h, --help / -v, --version
```

The stage flags are `-s`/`--start` and `-e`/`--end`, not `--start-stage` and
`--end-stage`. The sixteen stage names, in order:

```
initialize parseways parserelations parsenodes constructedges build enhance
filter transit bss hierarchy shortcuts restrictions elevation validate cleanup
```

There is no bounding-box, extent, region, or clip flag. Spatial limiting
happens either before the build, by clipping the PBF with `osmium extract`,
or after it, by selecting tiles with `valhalla_build_extract`. The only
config key that looks related, `mjolnir.transit_bounding_box`, limits transit
feed ingestion, not the road graph.

`-j` overrides `mjolnir.concurrency`. Note that `-e` means "end stage" here
and "extract tar" on `valhalla_build_extract`.

---

## `valhalla_build_extract`

```
usage: valhalla_build_extract [-h] [-c CONFIG] [-i INLINE_CONFIG]
                              [-e EXTRACT_TAR] [-O] [-t]
                              [-b BBOX | -g GEOJSON_DIR] [-v]
```

The long form of `-v` is `--verbosity`, not `--verbose`. `-O` overwrites an
existing output; `-t` adds a `traffic.tar` skeleton.

**`-e` is not an output-path flag.** Its help says: "If specified, will build
an extract from an existing tar file at `mjolnir.tile_extract` and save it
to this specified path." So passing `-e` also switches the *input* from
`mjolnir.tile_dir` to whatever tar `mjolnir.tile_extract` points at, if that
file exists. To read from the tile directory and write to a per-pack path,
set the output through the config instead:

```sh
valhalla_build_extract -c config.json \
  -i '{"mjolnir":{"tile_extract":"/out/pack-042.tar"}}' \
  -g /geojson/pack-042 -O -v
```

`-i` overrides the file config. `cut-packs.sh` uses this pattern.

**Selecting tiles.** `-b minx,miny,maxx,maxy` and `-g DIR` are mutually
exclusive. There is no `-r`/`--region` flag in 3.6.3. With `-g`:

- Every `*.geojson` file in the directory is read (a `.json` extension is
  skipped), every polygon from every file goes into one flat list, and every
  tile intersecting any of them goes into **one** output tar. Filenames are
  never used. To get one tar per region you must run the tool once per
  region, each time pointing `-g` at a directory holding only that region's
  file.
- The file must be FeatureCollection-shaped: a top-level `"features"` list
  whose members have a `"geometry"`. A bare Geometry or a bare Feature
  crashes with `KeyError: 'features'`. The top-level `"type"` isn't checked.
- Only Polygon and MultiPolygon members count; anything else is silently
  ignored. Only the outer ring is used, so holes are dropped.
- Matching is against each tile's bounding box, not its exact shape, so a
  region pack includes a fringe of tiles just outside the boundary.
- `-g` imports `shapely` lazily. shapely 2.0.3 is present in the image, so
  nothing needs installing.

---

## `valhalla_build_timezones`

This is a POSIX `sh` script with no argument parsing. **`--help` doesn't
print help; it runs the full build**, downloads the timezone shapefile, and
dumps a binary SQLite database to stdout. Don't call it to see what it does.

Things the script does that the build has to accommodate:

- It writes the database to **stdout** and progress to stderr. Redirect:
  `valhalla_build_timezones > /data/valhalla/tz_world.sqlite`.
- It downloads `timezones-with-oceans-1970.shapefile.zip` from the
  `evansiroky/timezone-boundary-builder` GitHub release at run time. The
  data version is hard-coded to `2025b`; no flag or variable changes it.
  With no network it exits 1 and leaves a **0-byte** file. A firewalled
  build box needs `github.com` and `objects.githubusercontent.com`
  reachable, or a pre-built database and `SKIP_TIMEZONES=1`.
- It needs `spatialite` and `unzip`. Its `error_exit` helper calls
  `pkg-config`, which isn't in the image, so the guard may not abort as
  loudly as intended. The build script checks the exit code and the output
  size itself rather than trusting the tool.

---

## `valhalla_build_config` defaults

Run with no arguments it prints the full default JSON (about 9.7 KB). The
keys the pipeline cares about:

| Key | Default |
|---|---|
| `mjolnir.tile_dir` | `/data/valhalla` |
| `mjolnir.tile_extract` | `/data/valhalla/tiles.tar` |
| `mjolnir.tile_url` | absent |
| `mjolnir.concurrency` | absent |
| `mjolnir.max_cache_size` | `1000000000` (bytes per thread) |
| `mjolnir.timezone` | `/data/valhalla/tz_world.sqlite` |
| `mjolnir.admin` | `/data/valhalla/admin.sqlite` |
| `mjolnir.hierarchy` | `true` |
| `mjolnir.include_driveways` | `true` |

`tile_url` and `concurrency` are declared optional in the generator and
**omitted** from the output unless you set them. Code that reads
`config["mjolnir"]["concurrency"]` without a default will `KeyError` on a
stock config; pass `--mjolnir-concurrency N` at generation time or `-j N` at
build time. The help text for these two shows a Python object repr as the
default, which is a cosmetic bug, not a real value.

An absent `tile_url` is also what guarantees the engine never fetches tiles
over HTTP. The app relies on the same property.

### Service limits

```json
"max_exclude_locations": 50,
"max_exclude_polygons_length": 10000,
"allow_hard_exclusions": false
```

`max_exclude_polygons_length` is the total **perimeter in metres** of all
`exclude_polygons` in a request: 10 km, or roughly fifty 30 m-radius camera
circles. Valhalla's API documentation and the comment in
`LocalValhallaEngine.swift` agree on this; the raw capture in `ai-docs/`
misread it as a vertex count, so don't trust that part of it. With
`allow_hard_exclusions` false, an over-limit request is refused rather than
truncated. The app raises the limit to 1,000,000 in its own engine config;
a server instance would use
`valhalla_build_config --service-limits-max-exclude-polygons-length N`.

---

## What's in the base image

| Tool | Present |
|---|---|
| `python3` 3.12, `shapely` 2.0.3, `curl`, `tar` | yes |
| `osmium`, `jq` | **no** |

`osmium` matters because `valhalla_build_tiles` has no clipping flag, so
clipping the PBF is the only way to limit graph extent before a build.
`server/builder/Dockerfile` adds osmium, pyosmium, and rclone on top of the
base image. Use `python3 -c 'import json, …'` rather than `jq` in build
scripts.

---

## Not verified

- No tile build was run during the capture; statements about
  `valhalla_build_tiles` and `valhalla_build_admins` come from help text.
- `valhalla_build_extract` was read, not executed end to end. The single-tar
  and `KeyError` conclusions follow directly from the source but weren't
  observed.
- Only `linux/arm64` was inspected. Whether the `linux/amd64` variant ships
  the same Python packages, notably shapely, is unconfirmed. Check before
  trusting `-g` on an x86_64 build box.
- Whether the router refuses or truncates an over-limit `exclude_polygons`
  request wasn't tested against a live service.
