# Architecture

How this repository is put together, where the data comes from, and why the
main decisions were made the way they were.

- What the app sends over the network: [PRIVACY.md](PRIVACY.md)
- Instructions for AI coding agents: [AGENTS.md](AGENTS.md)

---

## What it is

**You're Flocked** warns you when you're near ALPR (automated licence plate
reader) cameras and other surveillance devices. Camera locations come from
OpenStreetMap. The app does four things:

- warns you when you enter a camera's detection zone
- shows surveillance cameras on a live map
- lets you add cameras you find to OpenStreetMap
- plans routes that pass fewer cameras, on the device

iOS ships first (SwiftUI, MapKit, CoreLocation, SwiftData, iOS 17+, Swift 6).
Android is planned but not started.

### Names and identifiers

| | |
|---|---|
| Product name | **You're Flocked** |
| Icon label | **FLCKD** |
| Domain | flckd.app |
| App bundle ID | `io.vws.app.flckd` |
| Widget bundle ID | `io.vws.app.flckd.widgets` |
| User-Agent | `FLCKD/1.0 (iOS; +https://flckd.app)` |

Use **You're Flocked** in UI copy, permission strings, and anything a user
reads. Use **FLCKD** only where space is tight. Swift types use
`YoureFlocked` because identifiers can't contain an apostrophe.

---

## Repository layout

```
ios/          the iOS app
server/       tile build and distribution service for on-device routing
docs/         design notes
.github/      workflow that publishes the server's builder image to GHCR
android/      empty, planned
```

[`server/`](server/README.md) isn't part of the app. It builds the road data
the app downloads so it can plan routes without sending your location
anywhere. See [docs/on-device-routing.md](docs/on-device-routing.md).

### The app

```
ios/
  project.yml                       XcodeGen project definition, the source of truth
  Shared/
    SurveillanceActivityAttributes.swift   shared with the widget target
  YoureFlocked/
    YoureFlockedApp.swift           entry point
    ContentView.swift               tab navigation
    Models/
      SurveillanceCamera.swift      core model, parses OSM tags
      CachedCamera.swift            SwiftData model for the offline cache
      OverpassResponse.swift        Overpass JSON types
      SuspectedLocation.swift       unconfirmed locations from permit data
    Views/
      CameraMapView.swift           the main map
      CameraDetailView.swift        camera info sheet
      AddCameraView.swift           report a new camera
      RouteView.swift               route planner
      OfflineRoutingView.swift      tile server and region pack settings
      SettingsView.swift            settings
      ProximityBannerView.swift     the in-app proximity warning
      SplashView.swift              launch screen
      RoutingDebugOverlay.swift     debug only: the routing latency HUD
    ViewModels/
      MapViewModel.swift            map state, filtering, proximity coordination
      CameraStore.swift             central data store
    Services/
      OverpassService.swift         camera lookups, with retry and fallbacks
      DeFlockCDNService.swift       bulk ALPR tiles from DeFlock's CDN
      LocationManager.swift         location handling and distance checks
      ProximityAlertEngine.swift    proximity warnings: hysteresis, cooldown, trip tally
      NotificationManager.swift     local notifications
      ValhallaRoutingService.swift  request building, avoidance, scoring
      LocalValhallaEngine.swift     the embedded Valhalla engine
      TilePackService.swift         manifest, pack download, RegionStore
      USStateBounds.swift           rough region boxes for preflight UX
      SuspectedLocationService.swift  optional CSV download
      LiveActivityManager.swift     Live Activity on the lock screen
      RoutePlanMetrics.swift        debug only: one timed record per plan
      RoutingMetricsStore.swift     debug only: session stats and JSON export
      RerouteProbe.swift            debug only: repeated planning while driving
    Resources/
      Info.plist, entitlements, assets
  YoureFlockedWidgets/              widget and Live Activity target
  YoureFlockedUITests/              gitignored; contains real coordinates
```

The `.xcodeproj` is generated and isn't in git. Edit `project.yml`, then run
`xcodegen generate`.

### Pattern

```
Views (SwiftUI) -> ViewModels (@Observable) -> Services -> data (SwiftData + APIs)
```

- **Views** are UI only: no business logic, no network calls.
- **ViewModels** hold UI state and coordinate.
- **Services** are infrastructure: network, location, notifications, the
  routing engine.
- **Models** are plain structs, `Codable`, `Hashable`, `Identifiable`.

---

## Where the data comes from

### Cameras: OpenStreetMap, via DeFlock and Overpass

ALPR cameras come mainly from DeFlock's hourly, OpenStreetMap-derived
20-degree tiles. The app reads the public index at
`https://cdn.deflock.me/regions/index.json`, honours its expiry, and
downloads only the tiles that intersect the visible map area. Speed cameras
come from a live Overpass query. If the DeFlock CDN is unavailable, the same
Overpass query supplies all camera types.

The primary Overpass endpoint is
`https://overpass.deflock.org/api/interpreter`, with `overpass-api.de`,
`overpass.kumi.systems`, and `overpass.private.coffee` as fallbacks.

```overpassql
[out:json][timeout:25];
(
  node["man_made"="surveillance"]["surveillance:type"~"camera|ALPR"](south,west,north,east);
  node["highway"="speed_camera"](south,west,north,east);
);
out body;
```

`CameraStore` starts at most one fetch every five seconds and normally
reuses a covered area for at least 30 seconds. `OverpassService` backs off
exponentially on 429 responses and moves through the fallback endpoints when
a request fails.

Tags parsed:

| Tag | Values | Meaning |
|---|---|---|
| `man_made` | `surveillance` | required base tag |
| `surveillance:type` | `ALPR`, `camera`, `guard`, `gunshot_detector` | device type |
| `surveillance` | `public`, `outdoor`, `indoor` | where it watches |
| `surveillance:zone` | `traffic`, `parking`, `town`, `entrance` | what it watches |
| `camera:type` | `fixed`, `panning`, `dome` | hardware |
| `camera:mount` | `pole`, `wall`, `ceiling` | mounting |
| `direction` | `0`–`360` | compass degrees, clockwise from north |
| `manufacturer` | `Flock Safety`, `Motorola Solutions`, `Genetec`, … | vendor |
| `operator` | free text | who runs it |
| `highway` | `speed_camera` | a separate scheme for speed cameras |

Reference: [OSM wiki](https://wiki.openstreetmap.org/wiki/Tag:man_made=surveillance).
Licence and attribution obligations: [docs/deflock-data.md](docs/deflock-data.md).

### Suspected locations: ALPRWatch

`https://alprwatch.org/suspected-locations/deflock-latest.csv` provides
coordinates derived from utility permit filings. They aren't confirmed
sightings, so they render as a separate layer and the feature is off by
default.

### Road data: the tile server

Region packs for routing come from a static file server described in
[`server/README.md`](server/README.md). The default is `tiles.flckd.app`;
the address is a setting.

---

## Decisions worth knowing

### Proximity uses distance, not geofencing

iOS allows only 20 monitored regions at a time. A city block can have more
cameras than that, so system geofencing can't do the job.

Instead the app takes continuous location updates and compares them against
cached camera positions in memory. That comparison never leaves the phone.
DeFlock's app does the same.

Warning is the app's primary job, so it can't depend on which screen is
open. `ProximityAlertEngine` is owned by the app, not by a view, and the
banner is drawn above the tab bar. It used to live in `MapViewModel`: a
driver with a route on screen got no warning at all, because the banner was
map-only and foreground notifications are suppressed in favour of it.

### Routing runs on the device

`MKDirections` can't route around arbitrary places, so Apple's routing can't
support the core feature. The app uses Valhalla, which can: camera positions
are passed as polygons to exclude, and the routes that come back are scored
by how many cameras remain nearby.

Valhalla is compiled into the app through
[`valhalla-mobile`](https://github.com/rallista/valhalla-mobile) 0.6.3,
which embeds Valhalla 3.6.3. There's no routing endpoint and no routing
request; `ValhallaRoutingService` and `LocalValhallaEngine` contain no
network code at all. Road data arrives as per-region packs the user
downloads through `TilePackService`, built by [`server/`](server/README.md).
Tiles are memory-mapped binary structures, so builder and engine must be the
same Valhalla version, which is why both are pinned.

There's no network fallback. If no region pack covers the route, the planner
says so and offers the download.

Avoidance can't always succeed. In a dense area, excluding every camera can
make a route impossible, so `routeWithProgressiveAvoidance` degrades in
steps: exclude everything it can, loosen the exclusion set when Valhalla
reports no path, and report how many cameras were avoided rather than
implying all of them were. The user picks one of four avoidance levels that
trade how many cameras are fenced against how large each fence is.

Engine configuration, storage rules, and threading are in
[docs/on-device-routing.md](docs/on-device-routing.md).

### Routing diagnostics are debug-only, and enforced

Four files measure how long route planning takes: a per-plan record, a store
with session statistics and a JSON export, a probe that replans on a timer
while driving, and an on-screen HUD. They answered whether a reroute can
finish fast enough to be useful to a moving car.

They never ship. Everything is inside `#if DEBUG`, so Release builds, which
is what Archive and TestFlight use, don't contain them. A Release build phase
then checks the binary for a sentinel string and fails if it finds one,
because verifying the artefact is worth more than trusting that the source is
still guarded.

The export holds no coordinates, but it isn't anonymous: pack size resolves
to a state against the public tile manifest, and timestamps with speed and
remaining distance describe a trip. Acceptable for a development device,
which is the only place it exists. See [AGENTS.md](AGENTS.md).

### The camera cache is a feature, not an optimisation

Fetched cameras are stored with SwiftData. On launch the cached set loads
immediately while a fresh fetch runs behind it, so the app is useful with no
signal, and proximity alerts keep working when Overpass is unreachable. For
a warning app that matters more than freshness.

---

## Building

Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd ios
cp Example.xcconfig Local.xcconfig   # put your own Team ID in it
xcodegen generate
open YoureFlocked.xcodeproj
```

Run `xcodegen generate` after a fresh clone and after every change to
`project.yml`. Signing identity comes from the gitignored `Local.xcconfig`,
so the tracked project carries no Team ID.

To test proximity alerts without driving around, use Xcode's
**Debug → Simulate Location**. Location simulation is already enabled in the
scheme. Don't commit GPX files or coordinates that correspond to real
places; see [AGENTS.md](AGENTS.md).

---

## Roadmap

**Working**

- MVVM scaffold
- Overpass client with retry and fallback endpoints, plus DeFlock CDN tiles
- Camera model with full OSM tag parsing
- Map with camera markers
- Distance-based proximity alerts and local notifications
- Settings: alert radius, filters, data sources, units, haptics
- Route planner with progressive camera avoidance and scoring
- On-device routing with downloadable region packs and a configurable tile
  server
- Field-of-view cones for cameras that record a `direction`: drawn on the
  map, offered as an "in field of view" alert mode, and used as wedge-shaped
  exclusion zones when routing
- Live Activity on the lock screen

**Next**

- Verify the SwiftData cache under real use; it's wired up, not proven
- Measure real pack sizes with a full server build
- App icon and launch screen polish
- Turn-by-turn guidance on top of the on-device engine
- CarPlay

**Later**

- Sign in to OpenStreetMap and submit cameras from the app (OAuth2, API v0.6)
- Edit and delete existing camera nodes, with changeset handling
- Android: Kotlin, Compose, Room

---

## Reference projects

| Project | Notes |
|---|---|
| [DeFlock Web](https://github.com/FoggedLens/deflock) | Vue 3 web app, MIT |
| [DeFlock App](https://github.com/FoggedLens/deflock-app) | Flutter mobile app, AGPL-3.0 |
| [EFF Atlas of Surveillance](https://atlasofsurveillance.org) | Agency-level data |
| [ALPRWatch](https://alprwatch.org) | Suspected locations from permits |
| [OSM surveillance wiki](https://wiki.openstreetmap.org/wiki/Tag:man_made=surveillance) | Tag documentation |
| [Overpass Turbo](https://overpass-turbo.eu) | Test queries interactively |

---

## Code standards

**Swift**

- `@Observable`, not `ObservableObject` + `@Published`
- `actor` for services that do async work; the Valhalla engine is the one
  exception and uses a serial `DispatchQueue` because its calls block
- SwiftData `@Model` for persistence, not Core Data
- The iOS 17 `Map(position:)` API, not the deprecated `Map(coordinateRegion:)`
- Don't swallow errors with a bare `try?`. Log or propagate.
- Models are `Codable`, `Hashable`, `Identifiable` by default

**Everywhere**

- No API keys in source. Use `.xcconfig` or build settings.
- Send the `FLCKD/1.0 (iOS; +https://flckd.app)` User-Agent on every
  request.
- Respect Overpass rate limits.
- Location data stays on the device. No analytics, no tracking, no
  telemetry.
- If a change adds a network call, changes what is sent, or adds a
  dependency, update [PRIVACY.md](PRIVACY.md) in the same commit.
