# Privacy Policy — FLCKD (You're Flocked)

**Last updated:** 2026-10-29

FLCKD warns you when you're near surveillance cameras. This document
describes what the code actually does, including the parts that aren't
flattering.

Everything here can be checked against this repository. If you find a
mismatch between this document and the source, the source is what's true.
Please open an issue.

---

## Summary

- There is no account, no sign-up, and no user identifier.
- There is no analytics, no telemetry, no crash reporting, and no
  advertising.
- Routing happens on your device. Your start point and destination are never
  sent anywhere. There is no routing server.
- No location history is written to disk, and no position ever leaves the
  device. Camera data is requested by whole-degree grid cell (about 111 km
  by 85 km), so the most any camera-data server learns is which cell you
  are in, and each cell is asked for at most once a day.
- The routing map packs are static files in a Cloudflare R2 bucket. There is
  no server of mine in the path, so nothing of mine sees or logs the
  request. Cloudflare does see your IP address and which pack you fetched,
  under its own policy.

The app is not fully offline. It still asks DeFlock and OpenStreetMap
services for camera data and Apple for map imagery. The camera requests
name a grid cell, never a position. The table below says exactly what.

---

## How routing works

The route planner runs entirely on your phone.

You download map data for a region you choose, a state-sized pack. From then
on, planning a route is a calculation over data already in your phone's
storage. No coordinates are sent and no request is made. The route planner
works in airplane mode.

A hosted routing service would have to be told where you are and where
you're going. That's the most sensitive pair of coordinates this app could
produce, and handing it to a third party would undermine the reason the app
exists.

The routing engine is
[`valhalla-mobile`](https://github.com/rallista/valhalla-mobile) (MIT),
compiled into the app. It's the one piece of third-party code in the
binary. It has no analytics and makes no network calls of its own: its
tile-download setting is left empty, and the engine skips its HTTP fetcher
when that value is empty.

The map data comes from a tile server. See
[About the tile server](#about-the-tile-server) for what it learns and how
to run your own.

---

## What leaves your device

| Destination | What it receives | When |
|---|---|---|
| **DeFlock CDN**<br>`cdn.deflock.me` | The public camera index, then the 20-degree ALPR data tile or tiles that intersect the grid cell being loaded. A tile name reveals a coarse area, not an exact position. | While the app is open: when a cell is loaded and its tile is missing or out of date |
| **OpenStreetMap Overpass**<br>`overpass.deflock.org`, then `overpass-api.de` if that fails | One whole-degree grid cell, as four integers, for speed-camera data. If the DeFlock CDN is unavailable, the same cell is asked for ALPR and other camera data too. The cell is fixed to the global degree grid, not to you: every phone in the same cell sends the same bytes. The query is sent in the request body, not the URL. If "Show Speed Cameras" is off and the CDN is up, nothing is sent here. | While the app is open, the first time you are in a cell, or view one on the map, or plan a route through one; then not again for that cell for a day |
| **Apple (MapKit)** | Map tiles for the area you're viewing. In the route search field, the text you type plus the map region. | While the map or route search is open |
| **Tile server**<br>default `tiles.flckd.app` (a Cloudflare R2 bucket), configurable | Which region pack you're downloading. Nothing about your position. | Only while a region download is running |
| **ALPRWatch**<br>`alprwatch.org` | Nothing about you. A static file download. | Only if you switch on "Show Suspected Locations", which is off by default |

Route planning itself makes no network request: the engine runs on the
phone. Before it runs, the app loads camera data, through the two camera
rows above, for every grid cell in the rectangle that has the start and
destination at opposite corners, plus about 3 km of margin. If the planned
route goes outside that rectangle, the app also loads the cells around the
route. Cells loaded in the last day aren't asked for again. Those servers
learn which cells, never the two points or the roads you'll take.

Every request above also reveals your IP address to that server, as any
network request does. The app can't prevent that.

The app's own HTTP requests identify it with the header
`User-Agent: FLCKD/1.0 (iOS; +https://flckd.app)`.

### Links you tap

The camera detail screen and Settings contain ordinary web links. They open
your browser and send nothing unless you tap them.

| Link | What the site learns if you tap it |
|---|---|
| "View on OpenStreetMap" | The ID of the camera you were looking at, plus your IP |
| "View on DeFlock" | The ID of the camera you were looking at, plus your IP |
| OSM wiki, Atlas of Surveillance, DeFlock source (Settings) | That someone visited, plus your IP |

The first two reveal which camera you inspected, which is a hint about where
you are. They're there because verifying and correcting map data is useful,
and the choice is yours on every tap.

### In plain terms

Your route is private. Which part of the country you're in is not.

Nobody learns where you're driving, because the route is computed on your
phone. DeFlock receives requests for the camera-data tiles that cover the
grid cell being loaded. Overpass receives the grid cell, for speed cameras,
and for all camera types if the DeFlock CDN is down. Apple sees which part
of the world you're looking at and what you type into the search field.

The app has to know about the cameras around you to warn you about them, so
it loads camera data for the grid cell you are in, on whichever screen you
have open, and loads the next cell when you cross into it. On a motorway
that is about once an hour. A cell is a fixed box about 111 km by 85 km,
the same for everyone inside it, and once loaded it isn't asked for again
for a day. So over a long drive those servers could learn the sequence of
cells you passed through, at roughly one per hour. They cannot learn where
in a cell you were, which road you took, or where you started or stopped.

It wouldn't be true to say nothing ever leaves your device. This is what
does.

---

## About the tile server

Routing on the phone needs road data on the phone, and that data has to be
downloaded from somewhere.

**What `tiles.flckd.app` is.** A Cloudflare R2 bucket of static files with a
custom domain and Cloudflare's cache in front. I upload the packs to it
once a month. There is no web server, no application, and no machine of
mine anywhere in the request path.

**What the request reveals.** Your IP address and which state-sized region
you asked for. That's a coarse hint about an area you're interested in, and
it's a real disclosure. It never includes your position, your route, your
destination, or anything you type.

**Who sees it.** Cloudflare, because it terminates the connection and
serves the file. I haven't turned on any Cloudflare logging or analytics
product (no Logpush, no Web Analytics), and R2 itself gives me storage and
bandwidth totals, not per-request logs. What I can see is whatever
Cloudflare shows every account by default, which is aggregate traffic
figures for the domain. What Cloudflare records for its own purposes, and
for how long, is governed by Cloudflare's privacy policy, not by me. The
point is that no server of mine exists to write a request log, so there is
nothing of mine that could be leaked, subpoenaed, or breached.

**You don't have to use it.** The app takes a tile server address in
Settings. The packs are ordinary static files and the complete build recipe
is in this repository under [`server/`](server/README.md), so you can serve
them from a machine at home with no Cloudflare and no third party in the
path. If you
point the app somewhere else, it never silently falls back to
`tiles.flckd.app`. A failure is shown to you rather than worked around.

**You can also skip it.** Region packs are ordinary files. Sideload one,
download it over a VPN, or fetch it once on a network you don't mind being
seen on. Once the pack is on the phone, routing needs nothing further.

**How the packs are made.** The builder in [`server/`](server/README.md)
downloads OpenStreetMap extracts, daily changes and region boundaries from
Geofabrik, plus timezone boundaries from GitHub. It publishes road data
locally and, when enabled, uploads that site to the operator's configured
S3-compatible service, including R2. These services see the builder's IP
address and requested files; bucket uploads also carry authentication.
No mobile-user coordinates or routes are sent by the builder.

The self-hosted image runs a Bun/Hono control application with native
SQLite storage and a React/Radix UI built by Vite. Bun serves separate
builder and public tile endpoints. Tile requests are not forwarded to
the builder API. Neither endpoint writes request access
logs. The default Cloudflare-hosted service remains separate from the
builder machine.

Operators can enter publishing credentials in the control UI or override
them through environment variables. Saved credentials, preferences, job
history and bounded build logs stay in the private SQLite volume. Saved
credentials are **not encrypted at rest**; protect that volume and its
backups. Secrets are not returned by the settings API, included in the
public site, or stored in browser persistent storage. Pipeline logs redact
configured credential values. The builder is localhost-only by default and
has no login, session cookies or user accounts; it must not be exposed to
untrusted networks. `BUILDER_ENABLED=false` runs the public endpoint without
opening the private database or starting the builder.
The UI uses no analytics, external fonts or third-party browser requests.
Local development downloads dependencies and Docker images from their
registries; it does not send mobile-app traffic to those registries.

---

## What stays on your device

- Region map packs, the routing data you downloaded. These describe roads,
  not you.
- Cached camera records (SwiftData). These describe cameras, not you.
- Your settings (alert radius, filters, map preferences) in standard iOS
  preferences storage.

That's all. There's no location log, no visit history, and no route
history. Uninstalling the app removes all of it.

---

## Permissions

**Location, "Always".** Proximity alerts are the core feature, and they have
to work while the app is in the background, for example while you're
driving. Location is read continuously and compared against cached camera
positions on your device. That comparison never leaves the phone.

The app asks for background location so it can warn you before you pass a
camera rather than after. If you grant "While Using" instead, the map and
route planner still work, but background alerts won't.

**Notifications.** Used only to deliver proximity alerts, sent locally by
your phone. There's no push server.

---

## Reducing your exposure

- Leave Suspected Locations off unless you want it. It's off by default.
- Know that the speed-camera query goes out as soon as the app has your
  position, for the whole-degree grid cell you are in, unless that cell was
  loaded in the last day. Panning the map to a new cell sends that cell; it
  doesn't unsend the first one. Switching off "Show Speed Cameras" in
  Settings stops the query entirely. ALPR data comes from DeFlock's
  20-degree tiles, which reveal an even coarser area.
- Use a VPN to hide your IP address from the OpenStreetMap servers and from
  whichever tile server you use.
- Once cameras for an area are cached and the region pack is downloaded,
  both proximity alerts and route planning work with no network at all.

---

## Children

The app isn't directed at children and collects nothing from anyone.

---

## Changes

Any change to this document is visible in this repository's commit history.
That history is the changelog.

---

## Verify this yourself

The relevant code is small:

```
ios/YoureFlocked/Services/OverpassService.swift          camera lookups
ios/YoureFlocked/Services/DeFlockCDNService.swift        bulk ALPR camera data
ios/YoureFlocked/Services/TilePackService.swift          region pack downloads
ios/YoureFlocked/Services/ValhallaRoutingService.swift   route planning
ios/YoureFlocked/Services/LocalValhallaEngine.swift      the on-device engine
ios/YoureFlocked/Services/SuspectedLocationService.swift optional CSV download
ios/YoureFlocked/Services/LocationManager.swift          on-device location handling
```

To confirm there are no hidden network calls, search the whole source for
URLs:

```bash
grep -rn 'https\?://' --include='*.swift' ios/
```

Runtime service URLs in the results are covered by the table above or by
"Links you tap". Documentation and source-reference URLs in comments aren't
network requests.

To confirm routing specifically never touches the network, the routing
service and the engine wrapper should contain no `URLSession`, no
`URLRequest`, and no endpoint constant:

```bash
grep -nE 'URLSession|URLRequest|https?://' \
  ios/YoureFlocked/Services/ValhallaRoutingService.swift \
  ios/YoureFlocked/Services/LocalValhallaEngine.swift
```

That should print nothing.

---

## Contact

Open an issue in this repository.
