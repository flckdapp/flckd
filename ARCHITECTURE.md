# Architecture

How this repository is put together, where the data comes from, and why the
main decisions were made the way they were.

- What the app sends over the network: [PRIVACY.md](PRIVACY.md)
- Instructions for AI coding agents: [AGENTS.md](AGENTS.md)

---

## What it is

**You're Flocked** warns you when you're near ALPR (automated licence plate
reader) cameras and other surveillance devices. Camera locations come from
OpenStreetMap. The app does five things:

- warns you when you enter a camera's detection zone
- shows surveillance cameras on a live map
- lets you add cameras you find to OpenStreetMap
- plans routes that pass fewer cameras, on the device
- gives turn-by-turn directions along that route, and replans around cameras
  if you leave it

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
    LiveActivityContent.swift              composes the camera and turn halves of its payload
    ManeuverType.swift                     Valhalla maneuver codes, names and turn icons
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
      OfflineUpdateBanner.swift     "update available" / "updated" notice
      SplashView.swift                launch screen
      RoutingDebugOverlay.swift       debug only: the routing latency HUD
      Navigation/
        NavigationView.swift          the driving screen: map, turn card, controls, arrival card
        NavigationBannerView.swift    the turn card
        NavigationStatusChips.swift   rerouting, rerouted and reroute-failed notices
        TripSummaryView.swift         the arrival card
        NavigationFormat.swift        distance, duration and arrival-time text
    ViewModels/
      MapViewModel.swift            map state, filtering, proximity coordination
      CameraStore.swift             central data store
    Services/
      OverpassService.swift         fallback camera lookups by grid cell, with retry
      DeFlockCDNService.swift       bulk ALPR tiles from DeFlock's CDN
      LocationManager.swift         location handling and distance checks
      ProximityAlertEngine.swift    proximity warnings: hysteresis, cooldown, trip tally
      NotificationManager.swift     local notifications
      ValhallaRoutingService.swift  request building, avoidance, scoring
      LocalValhallaEngine.swift     the embedded Valhalla engine
      TilePackService.swift         manifest, pack and speed-camera file download, RegionStore
      OfflineDataUpdater.swift      daily update check for packs and the camera file
      USStateBounds.swift           rough region boxes for preflight UX
      SuspectedLocationService.swift  optional CSV download
      LiveActivityManager.swift     Live Activity on the lock screen: camera warning and next turn
      Navigation/
        NavigationSessionController.swift   one FerrostarCore per trip; state, voice, reroutes, summary
        FlckdRouteProvider.swift            Ferrostar's route provider, over the on-device planner
        NavigationLocationAdapter.swift     feeds Ferrostar from the app's one LocationManager
        FlckdNavigationWidgetProvider.swift Ferrostar's widget hook, onto the shared Live Activity
        ManeuverSymbol.swift                OSRM type and modifier to the app's ManeuverType
        NoNetworkRequestLoader.swift        the request loader Ferrostar is given; always throws
        VoicePrompt.swift                  utterance model, priority queue and sample-frame join timeline
        VoicePromptPlayer.swift            serial AVAudioEngine playback and on-device speech fallback
        VoicePCM.swift                     silence trimming, fixed gaps and click-free fades
        GuidancePromptSelector.swift       pure maneuver, distance and lane clip selection
        CameraPromptSelector.swift         pure camera type, clip and preference gating
        RouteSignals.swift                 optional on-device trace_attributes and signal-to-turn mapping
      RoutePlanMetrics.swift        debug only: one timed record per plan
      RoutingMetricsStore.swift     debug only: session stats and JSON export
      RerouteProbe.swift            debug only: repeated planning while driving
    Resources/
      Info.plist, entitlements, assets
      VoicePrompts/{male,female}/     generic recorded prompts; one folder reference preserves both voices
  YoureFlockedWidgets/              widget and Live Activity target
  YoureFlockedUITests/              gitignored; contains real coordinates
```

The `.xcodeproj` is generated and isn't in git. Edit `project.yml`, then run
`xcodegen generate`.

`scripts/voice-prompts/` holds the generic phrase script and development-only
ElevenLabs generation and normalization tools. Raw output stays in gitignored
`ai-docs/`; only the finished audio ships. See its README to regenerate it.

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

### Cameras: OpenStreetMap, via DeFlock, the tile server and Overpass

Speed and red-light cameras come from a national file the tile server
publishes next to the region packs (`/v1/cameras/<sha256>.json`, listed as
`speed_cameras` in the manifest). The builder extracts it from the same OSM
extract as the roads, refreshes it on its own schedule (daily by default),
and reads both tagging schemes: `highway=speed_camera` nodes and
`type=enforcement` relations with `enforcement=maxspeed`, `average_speed`
or `traffic_signals`, placed on their `device` member. `OfflineRoutingView`
downloads it after a pack installs and when the catalog is opened with a
region installed; `TilePackService` checks its sha256 and `SpeedCameraFile`
stores it in Application Support. While it exists, `CameraStore` takes
speed cameras from it and never asks Overpass for them. See
[server/README.md](server/README.md#speed-cameras).

`OfflineDataUpdater` keeps the packs and the camera file current. When the
app becomes active, at most once a day and only if something has been
downloaded, it fetches the catalog and compares sha256s. With "Update
Automatically" on (the default) it downloads what changed, packs only over
a non-expensive, non-constrained network, and shows an "updated" banner;
otherwise, or if a download fails, it shows an "update available" banner
whose Update button downloads over any network.

Everything that still goes to the network is fetched by whole-degree grid
cell (`GridCell`), never by a box around the user. The grid is anchored at the equator and prime
meridian, so a cell's four corners are integers that are the same for every
phone inside it, and nothing in a request is derived from a position.
`CameraStore` keeps a record of which cells it has loaded and asks for a
cell again only when that record is older than the cache TTL (a day). The
proximity engine calls the store on every location update; those calls are
no-ops until the user crosses into a new cell.

ALPR cameras come mainly from DeFlock's hourly, OpenStreetMap-derived
20-degree tiles. The app reads the public index at
`https://cdn.deflock.me/regions/index.json`, honours its expiry, and
downloads only the tiles that intersect the cell being loaded.

Overpass is the fallback. Before the speed-camera file has been downloaded,
speed cameras come from an Overpass query for the cell, cached on disk per
cell. If the DeFlock CDN is unavailable, one Overpass query for the cell
supplies the other camera types. If "Show Speed Cameras" is off, speed
cameras are dropped from the store, and Overpass is not queried at all
while the CDN is up.

The primary Overpass endpoint is
`https://overpass.deflock.org/api/interpreter`, with `overpass-api.de` as
the fallback. A single fetch is sent to at most two hosts. The query goes
in a POST body, not the URL.

```overpassql
[out:json][timeout:25];
(
  node["highway"="speed_camera"](lat,lon,lat+1,lon+1);
  node["enforcement"~"(^|;)(maxspeed|average_speed|traffic_signals)(;|$)"](lat,lon,lat+1,lon+1);
  relation["type"="enforcement"]["enforcement"~"(^|;)(maxspeed|average_speed|traffic_signals)(;|$)"](lat,lon,lat+1,lon+1);
);
out center;
```

The CDN-down variant adds
`node["man_made"="surveillance"]["surveillance:type"~"camera|ALPR"]`.
Relations get a representative point from `out center` and are stored with
a negated OSM ID so they can't collide with a node of the same number.

`CameraStore` also keeps a five-second floor between fetches as a guard
against a runaway caller; it is not the throttle. `OverpassService` backs
off exponentially on 429 responses and moves to the fallback endpoint when
a request fails, and serves a stale cell from disk if both fail.

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
| `type` | `enforcement` | relation scheme for speed and red-light cameras; `enforcement=maxspeed` etc. |

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

When no location fix is available, the map's user-follow camera falls back to a
fixed world rectangle, not automatic annotation framing. Its annotation set is
culled and clustered by viewport; using that changing set to reframe the viewport
creates an update loop on iOS 18.2 that can monopolize the main actor. A fixed
fallback also keeps the unit-test host responsive without suppressing the real
map or changing test timeouts. Once a location is available, user-follow tracking
still takes over normally.

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

The engine also keeps the camera set current, refetching once you've
travelled half the search radius from the centre of what's cached. Distance
rather than a timer, so it scales with speed and does nothing while parked.
Camera data used to be loaded once and never refreshed, so driving out of
that first box meant every camera beyond it was invisible to both warnings
and routing, with nothing to say so.

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

### Turn-by-turn navigation

Guidance runs on [Ferrostar](https://github.com/stadiamaps/ferrostar)
0.59.0 (BSD-3-Clause), pinned exactly: a Rust core that snaps the car to the
route, advances steps, detects deviation and times the prompts, behind a thin
Swift layer. The app links `FerrostarCore` only. Ferrostar's map views are
built on MapLibre; SPM resolves those packages but nothing links them, and
the driving screen is drawn with MapKit like every other screen.

The flow, start to finish:

1. The route planner's `routeWithProgressiveAvoidance` returns a
   `RoutePlan`: the chosen `ValhallaRoute`, the exact request JSON that
   produced it, and its index among that request's candidates.
2. "Start navigation" hands the plan to `NavigationSessionController`. It
   re-issues the same request to the same engine with `format: osrm`,
   `banner_instructions`, `voice_instructions` and `shape_format: polyline6`
   (`ValhallaRoutingService.navigationResponse(for:)`), parses the answer
   with Ferrostar's OSRM parser (`FlckdRouteProvider.routes(fromOSRM:)`), and
   picks the candidate at the plan's index after checking its length
   (`select(_:for:)`).
3. A fresh `FerrostarCore` is built for the trip with the app's
   `NavigationLocationAdapter`, `FlckdRouteProvider`,
   `NoNetworkRequestLoader` and `FlckdNavigationWidgetProvider`, and
   `startNavigation(route:)` is called. The controller mirrors Ferrostar's
   published state onto an observable property; `NavigationView` draws the
   banner, the remaining geometry and the progress bar from it, Ferrostar's
    muted `SpokenInstructionObserver` stays silent, the app's recorded-prompt
    player speaks, and the widget provider pushes the next turn into
    `LiveActivityManager`.
4. On deviation Ferrostar asks the delegate; the controller answers
   `.getNewRoutes` unless the car is within 100 m of the destination.
   `FlckdRouteProvider.getRoutes` runs the progressive-avoidance planner
   from the current position and heading, at the avoidance level the trip
   started with, against the cameras `CameraStore` holds for the corridor
   plus the ones the preview was planned against, then re-issues the winner
   as OSRM. The screen shows "Rerouting…", then "New route avoids N of M
   cameras"; the lock screen shows the spinner too.
5. On `.complete` the controller builds the trip summary, shows the arrival
    card, lets the final arrival utterance finish, and tears the session down: Live Activity turn cleared, location
   manager back to its idle distance filter and auto-pause, engine
   keep-alive released. The same teardown runs on End and on a failed start.

Voice prompts are selected from each new spoken instruction, deduplicated by
`utteranceId`. Valhalla puts the upcoming maneuver in the current step's banner;
the step's own maneuver is the one at its start. The selector therefore uses
the current banner's primary content, the next step's roundabout exit number,
and the banner sub-content's lane information. Angles cannot identify an exit
number; an unknown or unsupported maneuver uses on-device speech rather than
guessing. Distances select the nearest imperial recording (the clip inventory
is imperial even with metric display units); below 150 m the action stands
alone. Long-gap "continue" reminders use `continue_long`. Only contiguous
one- or two-lane edge groups, or a single middle lane, get a lane recording,
and only on approach prompts. Reroute start and acceptance have recordings too.

After start and each accepted reroute, `RouteSignals` makes one on-device
`trace_attributes` call on the engine's existing serial queue. Its returned
polyline and edge end indices locate `end_node.traffic_signal` nodes. The
request filter is `node.traffic_signal`, not `end_node.traffic_signal`. An edge's
`traffic_signal` flag cannot locate a light along that edge and is not used to
invent a node. A node within 25 m of the maneuver, checked against route
progress as well as position to handle loops, enables light-based prompts.
Approaches name the next or second light only when zero or one other signal
lies ahead before the turn. Missing data, errors and results older than five
seconds silently leave ordinary prompts. Results are discarded on route
replacement or teardown; neither geometry nor positions are written down.

Spoken camera warnings hook the existing proximity engine's entry and 60 m
escalation events; they do not run another detector. Speech's escalation
one-shot is independent of the haptics toggle. Banners, notifications, haptics,
cooldowns and trip tally retain their existing behavior. ALPR manufacturer or
brand tags containing "flock" select Flock recordings; other ALPRs and cameras,
speed cameras and gunshot detectors each have their own clips. Unknown devices
and guards stay silent. Rear entry alerts are silent; field-of-view alerts and
passing have specific clips. Ahead groups use the two/three/several recording.

Settings shows one master Voice switch, default on, and a "Voice & Spoken
Prompts" page that holds everything else. That page starts with a voice list built
from `PromptVoice.allCases`, shown by name (Eric, Matilda), with a selection
checkmark and a preview button per row. Previews use that row's voice and replace
any previous preview, even with Voice off. They are refused while starting or
navigating, so they never interrupt or wait behind a live direction.

Spoken prompts has separate directions, traffic-light, rerouting and camera
switches, disabled under the master switch. The existing `voiceGuidanceEnabled`
key still controls directions only; camera alerts and rerouting are independent.
Camera alerts default to while navigating. Also when not navigating enables
them outside a trip, and four per-type switches default on. The old
`spokenCameraAlertMode` migrates once into the camera and outside-navigation
switches without overriding a saved new preference. The driving screen's mute
is in-memory and per-trip, silences directions and cameras alike, and never
changes a persisted preference. With master Voice off, its button shows silence
and is disabled rather than suggesting it can override Settings.

`VoiceSettings` is the pure permission policy shared by the controller, proximity
engine and player. Producers pass lane/signal permissions into the pure guidance
selector; disabled lights use plain distance/turn recordings. The player also
rechecks queued utterances at playback and stops disallowed active speech when
preferences or trip context change. All saved settings use UserDefaults; there
is no additional route or position storage.

Decisions:

- **Ferrostar rather than guidance written here.** Snapping, step advance
  on looping detours, deviation with accuracy gating and prompt timing are
  where a navigation stack spends its bugs. Ferrostar's core is the one
  place those are being fixed with other people's drives, and the same Rust
  runs on Android, so the port keeps the hard half. The risk it carries,
  step skipping on hairpins, is exercised in
  `NavigationRerouteBehaviourTests` on synthetic detour geometry.
- **One Live Activity, not two.** Ferrostar's own activity attributes are
  internal, and a second activity would compete with the camera warning for
  the lock screen. The app's `ContentState` carries both halves, composed
  from both sources on every update so neither blanks the other, and the
  turn half is optional so a payload written before turns existed still
  decodes.
- **The preview stays in Valhalla's native format; the OSRM response is
  re-issued for the chosen request.** The planner's scoring parses the
  native response and that is well tested. Replanning at start could
  legitimately return a different route from the one the user agreed to, so
  start re-runs the exact winning request in OSRM format instead. Valhalla
  is deterministic, so the candidate order holds; the length check makes a
  mismatch degrade to the primary route rather than navigate an alternate
  the user never saw.
- **The app owns the audio session.** Ferrostar gets a muted no-op synthesizer
  with `managesAudioSession: false`. `VoicePromptPlayer` confines all audio
  work to one serial queue. It activates `.playback` / `.voicePrompt` with
  `.duckOthers` and `.interruptSpokenAudioAndMixWithOthers` once per utterance
  and releases with `.notifyOthersOnDeactivation` after the final clip, never
  between an approach and its lane sentence. `AVAudioFile` decodes generic
  recordings to a per-voice PCM cache. Residual source/encoder silence is
  trimmed, then a single `AVAudioPlayerNode` buffer contains the whole
  utterance with fixed 350 ms sentence gaps and 8 ms endpoint fades; a 120 ms
  intra-sentence constant is reserved for future joins. Guidance wins between
  utterances, camera alerts wait for the current one and expire after five
  seconds. A missing clip falls back to on-device `AVSpeechSynthesizer`,
  preferring premium then enhanced installed voices for its language.
  Interruptions and unplugged outputs stop speech instead of resuming an old
  instruction. Background audio is declared for locked-screen prompts; no
  silence is played to keep the app running.
- **Drive simulation is debug-only.** A `Simulate drive` toggle under the
  route card replays the route through Ferrostar's
  `SimulatedLocationProvider` at 4x. It lives behind `#if DEBUG` with the
  rest of the diagnostics.
- **Thresholds.** Step advance: within 30 m of the end of a step, then 5 m
  past it, with fixes worse than 32 m ignored. Arrival: within 30 m.
  Deviation: a fix within 25 m accuracy more than 50 m from every remaining
  step. Reroute throttle: Ferrostar's 5 s and 50 m. They are in one place,
  `NavigationSessionController.navigationConfig`, and the behaviour tests
  use that same value.
- **The reroute callback hops.** Ferrostar calls
  `loadedAlternateRoutes` from its reroute task, off the main queue, unlike
  its other delegate calls. The controller's witness is non-isolated and
  hops to the main actor itself.

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
scheme. To test turn-by-turn without driving, Debug builds have a
**Simulate drive** toggle under the route card that replays the planned
route. Don't commit GPX files or coordinates that correspond to real
places; see [AGENTS.md](AGENTS.md).

---

## Roadmap

**Working**

- MVVM scaffold
- National speed-camera file from the tile server; Overpass by grid cell as
  the fallback, plus DeFlock CDN tiles
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
- Turn-by-turn guidance on the on-device engine: banner, spoken prompts, the
  next turn on the lock screen, camera-avoiding reroutes, an arrival summary

**Next**

- Verify the SwiftData cache under real use; it's wired up, not proven
- Measure real pack sizes with a full server build
- App icon and launch screen polish
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
