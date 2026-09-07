# Privacy Policy — FLCKD (You're Flocked)

**Last updated:** 2026-09-06

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
- No location history is written to disk, and none leaves the device.
- The routing map packs are static files in a Cloudflare R2 bucket. There is
  no server of mine in the path, so nothing of mine sees or logs the
  request. Cloudflare does see your IP address and which pack you fetched,
  under its own policy.

The app is not fully offline. It still asks DeFlock and OpenStreetMap
services for camera data and Apple for map imagery, and those requests
contain location information. The table below says exactly what.

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
| **DeFlock CDN**<br>`cdn.deflock.me` | The public camera index, then the 20-degree ALPR data tile or tiles that intersect the map area. A tile name reveals a coarse area, not an exact position. | While the map is open, when a tile is missing or out of date |
| **OpenStreetMap Overpass**<br>`overpass.deflock.org`, `overpass-api.de`, `overpass.kumi.systems`, `overpass.private.coffee` | A map bounding box, for speed-camera data. If the DeFlock CDN is unavailable, the same box is used for ALPR and other camera data too. When the map follows you, that box is centred on your position. | While the map is open |
| **Apple (MapKit)** | Map tiles for the area you're viewing. In the route search field, the text you type plus the map region. | While the map or route search is open |
| **Tile server**<br>default `tiles.flckd.app` (a Cloudflare R2 bucket), configurable | Which region pack you're downloading. Nothing about your position. | Only while a region download is running |
| **ALPRWatch**<br>`alprwatch.org` | Nothing about you. A static file download. | Only if you switch on "Show Suspected Locations", which is off by default |

Route planning isn't in this table because it doesn't make a network
request.

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

Your trips are private. Your map browsing mostly is, but not entirely.

Nobody learns where you're driving, because the route is computed on your
phone. DeFlock receives requests for the camera-data tiles that cover the
map area. Overpass receives a bounding box for speed cameras, and for all
camera types if the DeFlock CDN is down; that box is centred on you when the
map follows your position. Apple sees which part of the world you're looking
at and what you type into the search field.

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
- Know that the speed-camera query goes out as soon as the map has your
  position, centred on it, with a box at least about 10 km across and wider
  when you're zoomed out. Panning afterwards sends a new box for the new
  area; it doesn't unsend the first one. ALPR data comes from DeFlock's
  20-degree tiles, which reveal only a very coarse area.
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
