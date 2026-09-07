# Tile builder and server

One image runs the builder web application and a separate public tile
endpoint, both served by Bun. SQLite stores settings and job
history, and React with Radix components provides the Vite-built UI.
Valhalla 3.6.3 and its native tools are bundled. Nothing needs installing
on your host beyond Docker and, for the Bun commands, Bun.

## Quick start

From this directory:

```sh
bun install
bun run start
```

Or, with Docker alone:

```sh
docker compose up --build --wait
```

Open **http://localhost:8642** for the builder. The generated public site
is served at **http://localhost:8080**. Select regions, save settings, then
choose **Build now**. Nothing starts downloading road data until you start
a build or enable a schedule. The public index is available immediately,
but has no packs until a build succeeds.

The first startup downloads the image dependencies. Subsequent startups
reuse Docker's build cache. `bun run stop` stops the services without
removing their data. Do not use `docker compose down -v` unless you intend
to delete all settings, credentials, build data and published packs.

## Running from the published image

You don't have to clone this repository. CI publishes a multi-architecture
image (`linux/amd64` and `linux/arm64`) to
`ghcr.io/flckdapp/flckd/server`. Save this as `compose.yml` in an empty
directory and run `docker compose up -d`:

```yaml
name: flckd-server
services:
  server:
    image: ghcr.io/flckdapp/flckd/server:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:8642:8642"   # builder UI: keep this on loopback
      - "8080:8080"             # public tile endpoint
    env_file:
      - path: .env
        required: false
    volumes:
      - data:/data
      - site:/site
    stop_grace_period: 30s
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    healthcheck:
      test: [CMD-SHELL, "curl -fsS http://127.0.0.1:8080/health && curl -fsS http://127.0.0.1:8642/health"]
      interval: 5s
      timeout: 3s
      retries: 12
volumes:
  data:
  site:
```

Then open **http://localhost:8642**, as in the quick start above. Any
settings you want fixed by the operator rather than the UI go in a `.env`
file beside the compose file; see [Environment
variables](#environment-variables).

The tags are `latest`, `3.6.3` (the bundled Valhalla version, which the app
must match), and `sha-<commit>` for an exact build. Pin to a `sha-` tag if
you want reproducible restarts.

A build needs roughly 250 GB of scratch space in the `data` volume and
several hours. Put that volume on a disk that has it.

## Local development

```sh
bun install
bun run dev
```

This starts the same backend and native tools in Docker, then starts Vite
at http://localhost:8642 with frontend hot reload. The private backend is
on localhost:8090 and tiles remain on port 8080. Ctrl+C stops development
services, keeping their volumes. Production and development use separate
Compose projects and data volumes. Stop one before starting the other;
both use ports 8642 and 8080 by default.

If a local service already uses those ports, run
`FLCKD_UI_PORT=8643 FLCKD_TILE_PORT=8081 bun run dev`.
For production Compose, use `FLCKD_CONTROL_PORT` instead of `FLCKD_UI_PORT`.

Frontend edits reload immediately. Backend/script edits require restarting
`bun run dev`, which rebuilds the changed image layers. This deliberately
avoids a second host-native runner with different dependencies.

## Standalone Docker image

```sh
docker build -t flckd-server:local .
docker run --rm --name flckd-server \
  -p 127.0.0.1:8642:8642 -p 8080:8080 \
  -v flckd-data:/data -v flckd-site:/site \
  flckd-server:local
```

The image runs as UID/GID 568. Named volumes work without manual ownership
setup. For host bind mounts, make both directories writable by UID 568.
Mount `/data` and `/site` separately; private data must never be beneath
the public document root. No Docker socket is mounted in the container.

| Volume | Contents |
|---|---|
| `/data/control` | SQLite database, saved credentials and instance lock |
| `/data/work` | Source map, graph, scratch data and private job status |
| `/site` | Public index, logo, manifests and immutable pack parts |

Stop the container before backing up `/data/control`, so SQLite and its
WAL file are consistent. The database contains secrets: protect backups
just as you protect bucket credentials.

## Publishing to R2, S3 or another compatible bucket

The local site is always written. To upload it too:

1. Save your access key and secret in **Bucket credentials**.
2. Enable **Publish to bucket**, pick the provider and name the bucket.
   The remaining fields follow the provider: R2 asks for an account id,
   AWS for the bucket's region, anything else for a full endpoint URL.
3. Save settings and build. **Publish existing site** retries an upload
   without rebuilding the graph.

Saved secrets are private SQLite values, not encrypted at rest. They are
never returned to the browser or included in the public site. Blank inputs
keep existing secrets; **Clear saved credentials** removes saved values.
Use disk encryption and restricted volume permissions if local disk theft
is part of your threat model.

The bucket can also be configured from the environment instead of the UI;
see [Environment variables](#environment-variables) for the names.

HTTPS endpoints are required except for local/private development storage.
In Docker, `localhost` means the container itself. Use a reachable private
address or `host.docker.internal` for a host-side development bucket.
The app does not configure bucket public access or domains. R2 custom
domains need a `/` to `/index.html` rewrite. Preserve byte ranges and do not
compress the binary pack files at your CDN.

Immutable pack parts upload before the pointer manifest. Automated jobs
never delete remote objects; configure a deliberate retention policy if
you need to reclaim bucket space. Local release retention defaults to 3.

## Builds and schedules

The chosen states are the **entire next catalog**, not additions to the
previous one. Deselecting a state removes it from the next manifest.
All selected states share one schedule. Saving a new cadence schedules the
first run one interval later; use **Build now** for an immediate build.
The container must remain running for schedules. After downtime, missed
occurrences coalesce into one build. An interrupted build is recorded, not
silently rerun. Only one job runs at a time.

Selection also decides how much map is built. The source is clipped to the
selected states, with a margin so routes don't stop at a border, before the
graph is built. Scratch space and time scale with that clipped source: the
whole country is roughly 250 GB and several hours, a single state a few GB
and minutes. Selecting every state skips the clip and builds nationally.
Set `CLIP_SOURCE=0` to always build from the whole map.

A finished graph records the source it was built from. Building again from
an unchanged source reuses it and goes straight to cutting packs, so adding
states to the catalog costs minutes rather than a second full build. Set
`REBUILD_GRAPH=1` to force a rebuild.

Two threads need roughly 5 GB RAM. These are estimates, not guarantees.

The UI shows stages rather than invented completion estimates. Logs and
history survive restarts; only the latest 100 jobs and approximately 1 MiB
of log text per job are retained. Local and remote publication outcomes
are reported separately. Changing settings affects future jobs only.

For a smaller diagnostic build, explicitly pass `PBF_URL` and `PBF_NAME`
for a source extract and select only regions it covers. The UI does not
automatically determine geographic coverage of a custom source file.

## Keep the tile server independent

The builder API exists only on port 8642. Bun on port 8080 serves only
allowlisted site files, never credentials, logs or control APIs. Tile
downloads support HTTP byte ranges, ETag validation and immutable caching.
There is no nginx in the image.

To serve an already-generated site with the builder completely disabled:

```sh
docker run --rm -e BUILDER_ENABLED=false -p 8080:8080 \
  -v flckd-site:/site:ro flckd-server:local
```

This mode starts no builder listener, scheduler, database or build jobs.
It does not need a `/data` mount. Alternatively, the generated directory
is plain static files and works with any independent static server.
Bucket-hosted sites remain available with the builder off.

The builder is a local tool: there is no login, token, cookie or user
management. Keep its port bound to localhost as shown. Do not expose it to
untrusted networks. Use SSH forwarding for remote operation. Host and
cross-site mutation checks stop unrelated websites driving the local API;
they are not a substitute for network isolation. No request access logs,
analytics or external fonts are enabled.

## Environment variables

Everything below is optional; the defaults run a working instance. For
Compose, put values in a `.env` file beside the compose file. For
`docker run`, pass `--env-file` or `-e`. An empty value is treated as
unset.

Anything in the first table is also a UI setting. Setting it in the
environment wins: the matching field is labelled and locked in the
browser, and the API rejects a write to it. Remove the variable and
restart to hand the field back to the UI.

| Variable | Default | Purpose |
|---|---|---|
| `BUILD_REGIONS` | unset | Comma-separated region IDs for the catalog |
| `BUILD_CADENCE` | `manual` | `manual`, `daily`, `weekly`, or `every_30_days` |
| `THREADS` | `2` | Build concurrency; roughly 1.5 GB RAM per thread |
| `S3_BUCKET` | unset | Bucket name; setting it also enables bucket publishing |
| `S3_ENDPOINT` | unset | HTTPS bucket API endpoint, not the public website URL |
| `S3_PROVIDER` | `Cloudflare` | `Cloudflare`, `AWS`, or `Other` |
| `S3_REGION` | `auto` | Bucket region; R2 ignores this |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | unset | Used instead of the saved credentials |
| `R2_ACCOUNT_ID` | unset | Derives `S3_ENDPOINT` when that is unset |
| `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | unset | R2-named aliases; used when the `S3_` name is unset |

Server process, read once at startup and not exposed in the UI:

| Variable | Default | Purpose |
|---|---|---|
| `BUILDER_ENABLED` | `true` | `false` serves only the public tiles: no builder listener, scheduler, database or jobs |
| `BUILDER_BIND` | `0.0.0.0` in the image | Builder listen address inside the container |
| `BUILDER_PORT` | `8642` | Builder listen port inside the container |
| `BUILDER_ALLOWED_HOSTS` | unset | Extra `Host` values to accept, comma separated, for a deliberately configured private setup |
| `DATA_DIR` | `/data` | Private data: SQLite, credentials, source map, graph and scratch |
| `DOCROOT` | `/site` | Published site the tile endpoint serves; must not contain `DATA_DIR` |
| `REGION_SET` | bundled `us-states.json` | Region catalog file |
| `BIN_DIR`, `SITE_DIR`, `FRONTEND_DIR` | bundled paths | Where the image keeps the build scripts, dashboard assets and compiled UI |

Passed through to a build when set, for diagnostic or constrained runs:

| Variable | Default | Purpose |
|---|---|---|
| `PBF_URL` | Geofabrik US extract | Source map to download |
| `PBF_NAME` | `us-latest.osm.pbf` | File name of that source map |
| `SKIP_PBF_UPDATE` | unset | `1` reuses the map already on disk, skipping the download and diffs |
| `CLIP_SOURCE` | `1` | `0` builds from the whole source map even for a partial catalog |
| `CLIP_BUFFER_DEG` | `0.5` | Margin kept around the selected regions when clipping, in degrees |
| `REBUILD_GRAPH` | unset | `1` rebuilds the graph even when it matches its source |
| `KEEP_RELEASES` | `3` | Published releases retained locally |
| `PART_BYTES` | `134217728` | Bytes per published pack part |
| `MAX_CACHE_MB` | `700` | Per-thread graph tile cache |
| `SKIP_TIMEZONES` | unset | `1` uses a pre-staged timezone database instead of building one |
| `TMPDIR`, `HOME` | container defaults | Inherited by the build scripts |

A smaller source needs `PBF_URL` and `PBF_NAME` together, and you must
select only regions that source covers: the UI does not work out the
geographic coverage of a custom file.

Compose-file variables, which configure the host side rather than the
container, and only apply when you use this repository's `compose.yml`:

| Variable | Default | Purpose |
|---|---|---|
| `FLCKD_CONTROL_PORT` | `8642` | Host port for the builder UI, always bound to loopback |
| `FLCKD_TILE_PORT` | `8080` | Host port for the public tile endpoint |
| `FLCKD_TILE_BIND` | `0.0.0.0` | Host address the tile endpoint binds to |
| `FLCKD_UI_PORT` | `8642` | Vite's port during `bun run dev` only |

## Checks and internals

```sh
bun run check
bun test backend
bun run build
```

`backend/` owns HTTP, SQLite, scheduling and job execution. `frontend/`
owns the React UI. `shared/contracts.ts` defines the API boundary.
`builder/bin/` holds the native pipeline. `runtime/` starts Bun
under tini, with a single-instance file lock.

See [the Valhalla CLI reference](docs/valhalla-cli-reference.md) for format
requirements.
