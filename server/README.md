# Tile service

This builds the map data that lets the FLCKD app plan routes without sending
your location anywhere.

The app needs road data on the phone to do that. This service produces it:
it takes the raw OpenStreetMap file for the United States, turns it into
Valhalla routing data, splits it into one download per state, and serves
those downloads as plain files.

```
OpenStreetMap file for the US   (~12 GB, from Geofabrik)
        |
        v  build the routing graph                    hours
        |
        v  cut it into 53 state-sized packs           minutes
        |
        v  publish as immutable files
        |
        v  serve over HTTP  (Cloudflare R2, or your own box)
        |
        v  app downloads one state, routes on the phone
```

A tile host never learns where anyone is. The app asks for a whole state,
so the most it can tell is that somebody at this IP address wants Oklahoma.
The default host, `tiles.flckd.app`, is a Cloudflare R2 bucket with a
custom domain and cache rules and nothing else: no origin server, so there
is no server of ours that could write even that down. See
[What gets logged](#what-gets-logged).

You don't have to use the default host. The app has a setting for the tile
server URL, and everything needed to run your own is in this directory. See
[Run your own instance](#run-your-own-instance).

Which regions are currently published, how big they are, and when they were
last built is shown at [tiles.flckd.app](https://tiles.flckd.app), which
reads the same manifest the app does. This document doesn't track that.

---

## Quick start

Build one state and serve it locally. This proves the whole pipeline in
about ten minutes and uses a few GB of disk. You need Docker and roughly
5 GB free.

```bash
git clone <this repo>
cd flckd-app/server

# 1. Build Oklahoma. Downloads ~170 MB, then builds.
docker compose -f docker-compose.builder.local.yml run --rm builder \
  -c 'PBF_URL=https://download.geofabrik.de/north-america/us/oklahoma-latest.osm.pbf \
      PBF_NAME=oklahoma-latest.osm.pbf \
      run-build.sh oklahoma'

# 2. Serve what you just built.
FLCKD_DOCROOT=../_local/tiles docker compose -f origin/docker-compose.local.yml up
```

Then check it:

```bash
curl -s http://localhost:8080/v1/manifest.json | jq '.packs[].id'
# "oklahoma"
```

The `.local.yml` files write into `server/_local/` and run as your user, so
nothing needs root or a dedicated data directory. Delete it when you're
done.

Point the app's tile server setting at `http://<your-lan-ip>:8080` and
download Oklahoma. If your phone isn't on the same Wi-Fi, or you want this
to work away from home, use Tailscale; see
[Private instance over Tailscale](#private-instance-over-tailscale).

If the build fails, see [Troubleshooting](#troubleshooting).

---

## What you need

For the full United States:

| | |
|---|---|
| Free disk during the build | ~250 GB |
| Disk kept afterwards | ~20 GB |
| RAM | ~14 GB at 8 threads, ~5 GB at 2 threads |
| Time | roughly 4–8 hours |
| Network | ~12 GB download, plus access to `github.com` |

For one state, divide almost everything by about 70. Oklahoma needs roughly
4 GB of scratch disk and finishes in minutes.

Two things catch people out:

**Scratch disk, not the finished files, is the constraint.** The builder
writes large temporary files and deletes them at the end, so peak usage is
far higher than the result. Budget about 20× the size of the source map
file. The build script checks this before it starts and refuses rather than
dying halfway.

**RAM is set by the thread count, not the region size.** Eight threads
needs about 14 GB; two threads needs about 5 GB and takes roughly 50%
longer. If a build gets killed, lower `THREADS` first.

---

## How it works

Five steps. `run-build.sh` runs all of them.

1. **Update the source map.** `update-pbf.sh` keeps the US OpenStreetMap
   file current by applying Geofabrik's daily changes, so a monthly rebuild
   downloads about 300 MB instead of 12 GB.
2. **Build one national routing graph.** `build-graph.sh`. This is the
   expensive step. The graph covers the whole country at once because
   building it per state would be about 53× the work for the same output.
3. **Cut per-state packs.** `cut-packs.sh` slices state-sized files out of
   that one graph using the state boundaries Geofabrik publishes. This is
   cheap, so adding regions later costs minutes.
4. **Publish.** `publish.py` names every file after a hash of its contents,
   splits large ones into 128 MB parts, writes the index the app reads, and
   deletes old releases nothing points at any more.
5. **Serve.** Upload to Cloudflare R2, or serve the same directory from the
   included nginx config.

---

## Running a full build

The production Compose file pulls the prebuilt
`ghcr.io/flckdapp/flckd/builder:3.6.3` image (`linux/amd64` and
`linux/arm64`), which the GitHub Actions workflow in
`.github/workflows/publish-builder.yml` publishes whenever `server/builder/`
changes. Nothing compiles Valhalla on the build box. Pull the image before
the first build and whenever the builder changes:

```bash
docker compose -f docker-compose.builder.yml pull
docker compose -f docker-compose.builder.yml run --rm builder run-build.sh
```

The compose file has no local build context, so it runs anywhere Docker
Compose does. The image is public, so no registry credentials are needed. Before the first
run, set `FLCKD_DATA` to your data directory (see
[nginx origin on your own box](#nginx-origin-on-your-own-box)) and make
sure it's owned by UID 568, the user both containers run as.

It runs for hours. Watch progress from another terminal:

```bash
curl -s http://localhost:8080/v1/build-status.json
# {"build_id":"2026-09-01","stage":"build-graph","detail":"national graph, the long stage", ...}
```

To build a subset, name the regions:

```bash
docker compose -f docker-compose.builder.yml run --rm builder \
  run-build.sh oklahoma texas new-mexico
```

Region names come from `builder/regions/us-states.json`, which lists all 53
regions Geofabrik publishes for the US: 50 states, DC, Puerto Rico, and the
US Virgin Islands.

---

## Where the files go

```
/v1/manifest.json                          what the app reads first
/v1/releases/<build-id>/manifest.json      a snapshot of one release
/v1/packs/<hash>/part-0000.tar             the actual data
/v1/build-status.json                      progress while a build runs
/index.html                                static dashboard shell
/logo.png                                  static dashboard logo
/health                                    "is it up"
```

Every downloadable data file lives at a path derived from a hash of its
contents. That gives three useful properties:

- A state whose roads didn't change keeps the same URL, so caches keep
  serving it and nobody re-downloads it. Only states that changed cost
  bandwidth.
- A state that did change arrives at a new URL, so there's nothing to
  invalidate and no window where users get a stale mix.
- `/v1/manifest.json` is the only file ever overwritten, so it's the only
  tile-data object you ever need to purge from a cache.

The dashboard files are different: `origin/www/index.html` is uploaded to
`/index.html` and `origin/www/logo.png` to `/logo.png`. They're ordinary
root-level static objects, not immutable release files.

---

## Choosing where to host

Use Cloudflare R2 for a public instance. Use the included nginx config to
host it yourself. Both work: `run-build.sh` uploads to R2 when `R2_BUCKET`
is set and serves from the local directory when it isn't. You can run both
at once. `tiles.flckd.app` is the R2 option exactly as described below,
with no origin server behind it.

| | Your own box behind a CDN | Cloudflare R2 |
|---|---|---|
| Upload bandwidth from your house | every cache miss pulls from you | none |
| If your box is off | serves from cache for 30 days, then fails | unaffected |
| Cost | electricity and bandwidth | ~$0.30–0.60/month, downloads free |
| Cloudflare's terms | see below | fine |

Two things decide it for a public instance.

**Bandwidth.** On release day, every cache location that wants a changed
state pulls it from your origin, and that comes out of a home upload link.
With R2 there's no origin to pull from.

**Cloudflare's terms.** Their
[Service-Specific Terms](https://www.cloudflare.com/service-specific-terms-application-services/)
reserve the right to limit or disable the CDN for anyone serving "a
disproportionate percentage of pictures, audio files, or other large files"
without a paid product. Free, Pro and Business are all named, so a higher
plan doesn't help. Serving 15–20 GB of tile data through a proxied zone is
inside that clause. R2 is sold under different terms with no such
restriction. The risk isn't a bill; it's an outage on the day the app gets
popular.

R2 doesn't change two things: files over 512 MB still won't cache, so the
128 MB split stays; and Cloudflare still terminates the connection, so it
still sees client IP addresses.

### R2 setup

1. Create a bucket, for example `flckd-tiles`.
2. Attach a custom domain such as `tiles.example.com`. Don't use the
   `r2.dev` URL in production; it's rate limited and you can't apply cache
   rules to it.
3. Create an API token with Object Read & Write on that bucket.
4. Set `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID` and
   `R2_SECRET_ACCESS_KEY` in the builder environment. Use a secret, not
   literals in the compose file.
5. Apply the [cache rules](#cloudflare-setup) below to that hostname.
6. Add an exact-path Cloudflare URL Rewrite Rule for your hostname and path
   `/` that rewrites the path to `/index.html`. R2 custom domains don't
   provide an index fallback.

The upload publishes four root or pointer objects in addition to the
immutable packs and release manifests: `/v1/manifest.json`,
`/v1/build-status.json` when present, `/logo.png`, and `/index.html`.

Test the upload without changing anything:

```bash
DRY_RUN=1 docker compose -f docker-compose.builder.yml run --rm builder \
  push-r2.sh /srv/tiles
```

### nginx origin on your own box

Any host with Docker works. `origin/docker-compose.yml` mounts three
directories read-only and runs nginx as UID 568 with a read-only filesystem
and all capabilities dropped, so the setup is: make the directories, put
the config and dashboard files in them, hand them to that UID, start the
container.

```bash
export FLCKD_DATA=/srv/flckd          # wherever you keep it; this is the default
mkdir -p "$FLCKD_DATA"/{conf,www,tiles,build}
cp server/origin/conf/nginx.conf "$FLCKD_DATA"/conf/nginx.conf
cp server/origin/www/index.html server/origin/www/logo.png "$FLCKD_DATA"/www/
chown -R 568:568 "$FLCKD_DATA"
```

Both production compose files read `FLCKD_DATA` for their volume paths
(the builder writes into the same `tiles/` and `build/` directories the
origin serves). Export it, or put it in a `.env` file next to the compose
file, then:

```bash
docker compose -f server/origin/docker-compose.yml up -d
```

Nothing depends on the number 568. To run as a different user, change
`user:` in both compose files and chown to match.

The container listens on port 8080. Point a Cloudflare Tunnel or your
reverse proxy at it.

If the data lives on ZFS, set `recordsize=1M` on the dataset before writing
any tiles. The property only applies to files written after it's set.

---

## Cloudflare setup

Create four cache rules, in this order:

| # | Match | Setting |
|---|---|---|
| 1 | path starts with `/v1/packs/` | Cache. Edge TTL: use origin |
| 2 | path equals `/v1/manifest.json` | Cache. Edge TTL: use origin |
| 3 | path is `/index.html` or `/logo.png` | Cache. Edge TTL: use origin |
| 4 | path is `/health` or `/v1/build-status.json` | Bypass cache |

Also create one URL Rewrite Rule: when the request hostname is your tile
hostname and the path exactly equals `/`, rewrite only the path to
`/index.html`. Don't use a Worker for this.

Settings that matter:

- **Always Online: off.** It overrides the headers that keep your files
  available when your server is down.
- **Smart Tiered Cache: on.** Fewer origin fetches per release.
- Check that Cloudflare isn't compressing `.tar` files at the edge.
  Compression strips range support and breaks resumable downloads.
- Don't put the request method in a cache rule expression, and don't set a
  custom cache key. Both quietly break cache purging.

If you edit the cache headers: never send `s-maxage` or `must-revalidate`.
Either one tells Cloudflare it may not serve stale content, which means
that when your server goes down users get nothing instead of the copy
sitting in cache. It fails silently. The config sends neither.

The headers actually sent:

| Path | `Cache-Control` |
|---|---|
| `/v1/packs/**` | `public, max-age=31536000, immutable, stale-if-error=2592000` |
| `/v1/manifest.json` | `public, max-age=60, stale-while-revalidate=600, stale-if-error=2592000` |
| `/logo.png` | `public, max-age=86400` |
| `/index.html` | `public, max-age=300` |
| `/health`, `/v1/build-status.json` | `no-store` |

`stale-if-error=2592000` is what keeps downloads working for 30 days if your
build box is off.

---

## Keeping it up to date

Rebuild and publish monthly.

Every release is a full rebuild. Valhalla can't update tiles incrementally,
and patching individual tiles produces broken routes rather than errors, so
there's no shortcut. See [Design notes](#design-notes).

Monthly is what everyone else does. OsmAnd publishes monthly; Organic Maps
averages about three weeks. Nobody ships offline routing data faster.

Old data is tolerable for about three months, questionable at six, and
hard to defend at twelve. The failures are visible to users: a new road
missing, a route down a road that no longer exists, or directions sending
someone the wrong way down a street whose direction was flipped. That last
one is a safety problem.

There's also a hard deadline on the build side. Geofabrik keeps daily
changes for 100 days. If you skip more than three months, `update-pbf.sh`
can't catch up and has to re-download the full 12 GB file.

Camera data isn't in these tiles. It comes from the live Overpass feed and
updates independently. If the app ever shows a "your maps are five months
old" warning, it should say that's the road data, or people will assume
their camera data is stale too.

Suggested cron, first of the month:

```cron
0 3 1 * * cd /path/to/flckd-app/server && docker compose -f docker-compose.builder.yml run --rm builder run-build.sh
```

---

## Run your own instance

Nothing here is specific to `tiles.flckd.app`. This directory is the
recipe.

Three hard requirements:

1. Serve `/v1/manifest.json` and the `/v1/packs/**` files it points at.
2. Build with Valhalla 3.6.3. The app refuses packs built with anything
   else, because the data format is a memory-mapped binary layout and a
   mismatched version reads garbage.
3. Support byte ranges, so large downloads can resume.

Any static file host meets that: nginx, Caddy, S3, R2, or a Raspberry Pi.

The quick start above is a complete working instance. For a bigger one,
build the states you care about and copy the output directory to your host.

### Private instance over Tailscale

For a personal instance, with the server at home and the phone anywhere,
the easiest path is [Tailscale](https://tailscale.com). Nothing is exposed
to the public internet, there's no CDN or domain to set up, and your phone
can reach the server from anywhere.

With the origin container running (quick start step 2, or the nginx origin
above), pick one of two options on the host.

**Option A: HTTPS via `tailscale serve` (recommended).**

```bash
tailscale serve --bg 8080
```

Tailscale proxies the server at `https://<machine>.<tailnet>.ts.net` with a
real certificate. In the app, set the tile server to that URL. If you later
move the server to another machine, run the same command there and only the
machine name changes.

**Option B: plain HTTP over the tailnet.**

Set the app's tile server to the MagicDNS name:

```
http://<machine>.<tailnet>.ts.net:8080
```

The app ships an App Transport Security exception that allows plain HTTP to
`*.ts.net` only. Traffic is still encrypted on the wire by WireGuard. Use
the MagicDNS name, not the raw `100.x.x.x` IP; iOS ATS exceptions are
domain-based, so an IP-literal URL is still blocked.

Either way the three requirements are met: the manifest and packs are
served unchanged, and byte-range requests pass straight through.

If other people use your instance, tell them what you log. `nginx.conf`
includes a request-logging format, commented out. Turning it on is a
legitimate choice; just publish the fact.

---

## Configuration

All of these are environment variables on the builder container.

| Variable | Default | What it does |
|---|---|---|
| `THREADS` | all cores | Build concurrency. This is the memory dial. |
| `MAX_CACHE_MB` | `700` | Cache per thread. Lower it with `THREADS` if memory is tight. |
| `DATA_DIR` | `/data` | Working directory for the source file and the graph. |
| `DOCROOT` | `/srv/tiles` | Where published files are written. |
| `WWW_DIR` | `/srv/www` | Dashboard directory read by `push-r2.sh`; must contain `index.html` and `logo.png` when R2 upload is enabled. |
| `PBF_NAME` | `us-latest.osm.pbf` | Source map file name. |
| `PBF_URL` | Geofabrik US | Where to download it from. |
| `SKIP_PBF_UPDATE` | `0` | Set to `1` to reuse the file already on disk. |
| `BUILD_ID` | today's date | Release identifier. |
| `KEEP_RELEASES` | `3` | Old releases kept before pruning. |
| `PART_BYTES` | `134217728` | Split size. Don't raise above 512 MB. |
| `REGION_SET` | bundled US states | Region definitions to build from. |
| `R2_BUCKET` | unset | Set to enable the R2 upload step. |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | unset | R2 credentials. |
| `CF_ZONE_ID`, `CF_API_TOKEN` | unset | Set both to purge the manifest after publishing. |
| `PUBLIC_BASE_URL` | unset | Required if purging, e.g. `https://tiles.example.com` |
| `SKIP_TIMEZONES` | `0` | Set to `1` if you pre-staged the timezone database. |

Purging is optional. The manifest is cached for 60 seconds, so clients see
a new release within a minute even with no purge configured.

---

## Troubleshooting

**"not enough free space on /data"**
The check is deliberate; it stops the build before it wastes hours. You
need about 20× the source file size. Free space, or build fewer regions.

**The build is killed with no error, or the container exits with code 137.**
Out of memory. Lower `THREADS`. Halving it roughly cuts memory use by three
and adds about 50% to the runtime. On Docker Desktop or OrbStack, check the
VM's memory limit; that's the ceiling, not your machine's RAM.

**"valhalla_build_timezones failed"**
That step downloads a timezone boundary file from `github.com` at build
time. If your build box is firewalled, allow `github.com` and
`objects.githubusercontent.com`. Otherwise put a prepared
`timezones.sqlite` in the graph directory and set `SKIP_TIMEZONES=1`.

**"first tar member is X, expected index.bin"**
The publisher rejected a pack. The app memory-maps these files and requires
that index first, so a pack without it would fail on the phone instead of
here. Don't repack the files by hand; let `cut-packs.sh` produce them.

**Downloads restart from zero instead of resuming.**
Something in the path is compressing the files, which strips range support.
Check that Cloudflare isn't compressing `.tar` at the edge.

**Your server is down and users get errors instead of cached files.**
Check that no response carries `s-maxage` or `must-revalidate`, and that
Always Online is off. Any of those disables stale serving.

**nginx exits with "mkdir /var/cache/nginx/... permission denied".**
The container runs as UID 568 with a read-only filesystem, so its scratch
directories have to be tmpfs. Don't replace them with named volumes; those
are created owned by root.

**Geofabrik updates stop applying.**
If you skipped more than 100 days, the daily change files are gone. Delete
the source file and let `update-pbf.sh` download a fresh one.

---

## What the app expects

The app reads one URL and works from there.

```jsonc
GET /v1/manifest.json
{
  "schema": 1,
  "build_id": "2026-09-01",
  "osm_data_date": "2026-08-29",     // shown to the user
  "valhalla_version": "3.6.3",       // must match the app's engine
  "packs": [{
    "id": "oklahoma",
    "name": "Oklahoma",
    "iso3166_2": "US-OK",
    "bbox": [-103.0, 33.6, -94.4, 37.0],
    "bytes": 194000000,
    "sha256": "...",                  // of the whole reassembled file
    "parts": [
      { "index": 0, "path": "/v1/packs/<hash>/part-0000.tar",
        "bytes": 134217728, "sha256": "..." }
    ]
  }]
}
```

The app joins the parts in index order, checks each part's hash while
downloading and the whole file's hash at the end, then stores the file
without unpacking it.

Rules the app follows, which matter if you're writing a client or reviewing
this one:

- Never fall back to another server silently. If the configured server
  fails, show the error. Quietly falling back to `tiles.flckd.app` would
  send a request the user chose not to send.
- Send no credentials and no API key. The User-Agent identifies the app,
  not the user, and is the same for everyone.
- Verify before trusting. Check `schema`, check `valhalla_version` matches
  the built-in engine, check every hash. A hostile tile server should be
  able to waste your bandwidth and nothing more.
- Allow plain HTTP only for local addresses and `*.ts.net`, so people
  self-hosting at home don't need a certificate. Not a blanket exception.
- Show which server a pack came from, and how old it is.

---

## What gets logged

A record of which region an address downloaded, and when, is a location
record. It's weaker than GPS, but it's still a record, and the only way to
guarantee it's never leaked, subpoenaed, or breached is to never create it.
Infrastructure for a surveillance-awareness app shouldn't become
surveillance infrastructure itself.

**The default host, `tiles.flckd.app`.** There is no server. The packs sit
in a Cloudflare R2 bucket and Cloudflare serves them directly, so there is
no process of ours that could write a request log, and none is written. R2
reports storage and bandwidth totals, not requests. No Cloudflare logging
or analytics product has been turned on for the bucket or the zone; what
the account sees is Cloudflare's default aggregate zone analytics, and what
Cloudflare keeps for itself is under Cloudflare's policy.

What that doesn't remove: Cloudflare terminates every connection, so it
sees the client's IP address and the path requested, and it keeps whatever
its own policy says it keeps. That's the one third party in the path.
Anyone who doesn't want it there should self-host and accept the bandwidth
cost. The app supports that.

**The nginx config, if you self-host.** It logs nothing about requests
either. Stripping addresses out of a log format isn't enough, because
timing, sizes, and request order still link entries together, so request
logging is off entirely rather than anonymised:

```nginx
access_log off;
error_log /dev/stderr crit;
```

The `crit` level matters. At the usual `warn` or `error` levels, nginx
writes a line for every failed request, and those lines include the client
address, which would put request logging back in through the side door.
`crit` keeps real failures like crashes and resource exhaustion and says
nothing about individual requests.

An operator still has what they need to run it:

| Question | Where to look |
|---|---|
| Is it up? | `GET /health` |
| How busy is it? | `/nginx_status`, local network only |
| Did it crash? | container logs |
| Did a build fail, and where? | builder logs, `/v1/build-status.json` |

If you turn request logging on for your own instance, that's a legitimate
choice; just tell the people who use it.

---

## Layout

```
server/
  docker-compose.builder.yml        production build job, prebuilt image
  docker-compose.builder.local.yml  local source build for testing
  builder/
    Dockerfile                  Valhalla 3.6.3 + osmium + pyosmium + rclone
    bin/run-build.sh            one release, end to end
    bin/update-pbf.sh           keep the source map current
    bin/build-graph.sh          build the national routing graph
    bin/cut-packs.sh            cut per-state packs out of it
    bin/publish.py              hash, split, index, prune
    bin/push-r2.sh              upload to Cloudflare R2
    bin/poly2geojson.py         Geofabrik boundaries -> GeoJSON
    lib/common.sh               logging, disk checks, verified downloads
    regions/us-states.json      53 US regions
  origin/
    conf/nginx.conf             the origin config
    www/                        dashboard copied to the R2 bucket root
    docker-compose.yml          production origin deployment
    docker-compose.local.yml    local testing
  docs/
    valhalla-cli-reference.md   Valhalla 3.6.3 command notes and gotchas

.github/workflows/publish-builder.yml   builds and publishes the builder image
```

---

## Design notes

Why things are the way they are. Skip this unless you're changing
something.

**The Valhalla version is pinned to 3.6.3 and must stay pinned.** The iOS
package `rallista/valhalla-mobile` 0.6.3 embeds exactly that version. Tiles
are memory-mapped binary structures, so the program that writes them and
the program that reads them have to agree on the layout byte for byte.
Building with `:latest` would produce files the app can't read, and it
might fail by returning wrong routes rather than by erroring.

**There's no incremental update.** This isn't an optimisation that was
skipped. [valhalla#3386](https://github.com/valhalla/valhalla/issues/3386)
has been open since 2021; the maintainer states that rebuilding with an
extra regional file duplicates roads and still takes the full runtime, and
that swapping in a single rebuilt tile gives "crazy routes". There's no
change-file support in the codebase. `scripts/incremental_build_tiles`
upstream is misleadingly named; it runs the same full build, one stage per
process.

**Files are split into 128 MB parts** because Cloudflare won't cache an
object larger than 512 MB. It doesn't reject them; it quietly fetches them
from your origin on every request, which would hammer a home server and
fail completely when it's off. Parts are named `.tar` because that
extension is on Cloudflare's default cacheable list and `.part` isn't.

**Published files get a fixed timestamp.** nginx builds its cache validator
from the file's modification time and size and never looks at the contents.
Without a fixed timestamp, identical files would get a different validator
on every rebuild, and every client would re-download everything.

Don't replace that with a hand-written `ETag` header. nginx's revalidation
code reads an internal value that `add_header` doesn't set, so a custom
ETag makes every revalidation return the full file instead of a "not
modified" response, silently, showing up only as a bandwidth bill.

**Old files are removed by reference counting, not by age.** Packs are
shared between releases, so an unchanged state's data is still live even
though it was first published months ago.

**Memory numbers, for the record.** Measured upstream on four US states:
eight threads used 14.0 GB and took 11m26s; two threads used 4.65 GB and
took 17m10s. That's about 1.55 GB per thread plus 1.5 GB. Roughly the first
half of a build is single-threaded parsing, so extra cores don't help that
part. Valhalla publishes no official hardware requirements.

---

## Known gaps

What hasn't been proven yet.

- The US-wide size and time figures are estimates extrapolated from
  single-state builds, and those came in above their own estimates, so
  expect the national numbers to run high. Real pack sizes are on
  [tiles.flckd.app](https://tiles.flckd.app).
- The cache rules are live on `tiles.flckd.app` and the headers, cache
  status, and byte-range responses have been checked against a real pack.
  Stale serving when the bucket is unreachable hasn't been exercised.
- Disk read tuning on ZFS is unmeasured. ZFS handles caching differently
  from other filesystems, so the current settings are safe but not proven
  optimal.

---

## See also

- [`docs/on-device-routing.md`](../docs/on-device-routing.md): why
  on-device routing, which engine, and what it costs
- [`docs/valhalla-cli-reference.md`](docs/valhalla-cli-reference.md):
  Valhalla 3.6.3 command behaviour, including places where the upstream
  documentation is wrong
- [`PRIVACY.md`](../PRIVACY.md): what the app sends, and to whom
