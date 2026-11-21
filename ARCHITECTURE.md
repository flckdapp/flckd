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

iOS ships first (SwiftUI, MapKit, CoreLocation, SwiftData, iOS 26+, Swift 6).
Android is planned but not started.

iOS 26 runs on the iPhone 11 and SE (2nd generation) and later, so the
smallest supported phone has 3 GB of memory. The App Store can't filter by
memory or model, so the app installs on all of them. Nothing is gated by
memory: the live Phonon voice uses about 95 MB while speaking, so every
supported phone gets it.

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
    DistanceUnits.swift                    imperial default, shared preference key and formatter units
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
        NavigationMotionMap.swift     retained MapKit map, display-linked puck and follow camera
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
        GuidancePromptSchedule.swift       pure per-step continue, countdown and speed-scaled final triggers
        NavigationMotion.swift             pure path interpolation, fix intervals and speed-smoothed camera distance
        NavigationFollowState.swift        pure gesture/camera ownership and explicit recenter state
        DebugDriveSimulation.swift          debug only: uniform path samples, simulated speed and clock
        CameraExposure.swift                shared route distance geometry and speech-only observability predicate
        CameraPromptSelector.swift         pure camera type, clip and preference gating
        RouteSignals.swift                 optional on-device trace_attributes and signal-to-turn mapping
        PromptText.swift                   the sentence each clip says, numbers spelled out
        PhononSynthesizer.swift            actor-owned live speech, foreground load and fixed voice gains
        PhononSpeechService.swift          render-ahead window, bounded cache and background breaker
        SpeechAheadPlanner.swift           finite scheduled prompts for three steps
        NavigationVoice.swift              four-voice selection and legacy migration; no cross-voice fallback
        VoiceRenderPolicy.swift            deadline, duration limits and cache eviction
        VoiceResampler.swift               mono PCM sample-rate conversion
        PhononSentences.swift              sentence splitter, character gate and debug fixture examples
        PhononLoudness.swift               mono BS.1770 calibration on VoicePCM
        SpokenText.swift                   the word check every sentence passes before the engine sees it
        SpokenRoadName.swift               pure turn-card name to speakable words, or nothing
      RoutePlanMetrics.swift        debug only: one timed record per plan
      RoutingMetricsStore.swift     debug only: session stats and JSON export
      RerouteProbe.swift            debug only: repeated planning while driving
    Views/PhononEvaluationView.swift debug only: Phonon/recorded listening and short/long bench
    Resources/
      Info.plist, entitlements, assets
      VoicePrompts/{male,female}/     generic recorded prompts; one folder reference preserves both voices
      PromptText.json                 every clip's sentence, for live speech
      Licences/                       full licence texts for Phonon 31m and xn-ptts
  YoureFlockedWidgets/              widget and Live Activity target
  YoureFlockedUITests/              gitignored; contains real coordinates
```

The `.xcodeproj` is generated and isn't in git. Edit `project.yml`, then run
`xcodegen generate`.

`scripts/voice-prompts/` holds the generic phrase script and development-only
ElevenLabs generation and normalization tools. Raw output stays in gitignored
`ai-docs/`; only the finished audio ships. See its README to regenerate it.
`scripts/voice-model/fetch_phonon.py` prepares the bundled offline speech model.
Run it before building locally or in CI; the build fails if the verified model
folder is absent. No speech assets are fetched by the app.

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

Voice timing is app-owned. `GuidancePromptSchedule` consumes Ferrostar's
`TripProgress.distanceToNextManeuver` on every location-driven state update,
not Valhalla's `voiceInstructions` triggers. It deduplicates by accepted-route
step index and threshold, resets on step advance and reroute, and consumes all
crossed thresholds when a sparse fix jumps ahead, speaking only the nearest.
Heading changes do not publish progress; the location adapter requests 10 m
updates while navigating, not a fixed-frequency timer. Off-route fixes do not
consume the schedule.

At step entry, including departure and reroutes, a sufficiently long step gets
one "Continue on this road for..." prompt rounded to a quarter mile, up to ten
miles. Under an eighth of a mile it is omitted; over ten miles it uses the
generic recording. It is also omitted unless at least twelve seconds remain
before the first countdown, so short city steps do not get back-to-back prompts.
The imperial countdown uses 2 miles, 1 mile, half a mile and a quarter mile, only where
shorter than the step; sub-quarter-mile steps use 500 feet if there is room.
Final prompts fire six seconds ahead at current speed, clamped to 30-150 m.
An approach less than two seconds ahead of final is skipped. Missing speed uses
the route step's estimated speed. Imperial is the default, and metric is opt-in
through the single `DistanceUnits.storageKey` preference. Metric uses 2 km, 1 km,
500 m and 200 m, with 100 m for short steps; continue recordings round to half a
kilometer from 0.5 through 15 km, then use the generic clip. The speed-timed final
and minimum prompt gaps are shared. Changing units mid-step does not replay past
thresholds or the continue prompt. Pending speech in the previous units is
cancelled. Traffic-light and lane clips are unit-free and shared. Camera distance
clips use 200/300/400 m in metric, versus the existing imperial forms.

Both voices bundle 435 generic recordings, including 157 metric clips each
(115 approaches, 30 continue distances and 12 camera distances). The recorded
voices are never synthesized or downloaded at runtime. Runtime speech comes from the bundled Phonon model when Easton or Harper is
selected, or the recordings when Eric or Jessica is selected. Apple's
AVSpeechSynthesizer remains the recorded voices' existing last resort for
instructions with no matching recording, never a live voice fallback. The lock screen receives the app's
unit choice as an optional Live Activity payload field; absent means imperial,
including for payloads written by older builds. Both turn and camera distances
use explicit formatter units, never the device region. No App Group is needed.

Valhalla puts the upcoming maneuver in the current step's banner;
the step's own maneuver is the one at its start. The selector therefore uses
the current banner's primary content, the next step's roundabout exit number,
and the banner sub-content's lane information. Angles cannot identify an exit
number; an unknown or unsupported maneuver uses on-device speech rather than
guessing. Ferrostar's spoken instruction text is retained only as an on-device
fallback, never as the timing source. Approach prompts use distance recordings;
final prompts use the bare action even at the 150 m speed clamp. Only contiguous
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

Spoken camera warnings have their own eligibility and cooldown path, independent
of which nearest camera the banner shows. `CameraObservability` is the pure,
reusable visibility predicate; planner scoring and speech share its extracted
point-to-segment geometry and the planner's 35 m scoring radius. Speech adds a
conservative watched-road test, without changing route-planning decisions.

For directed cameras, the vehicle/route must be within 35 m, inside the model's
existing view wedge (35 degree half-angle by default, explicit ranges and
multiple directions honored), and traveling within that angle of the watched
road axis, in either direction. A route must contain at least 10 m of such
exposure. This rejects a perpendicular underpass even if it intersects the
camera's point. For cameras without a usable direction, speech requires a
5-25 m shoulder-like offset over at least 30 m of path. The 5 m exclusion rejects
ambiguous centerline crossings, but deliberately misses undirected overhead
cameras. Exposure windows are sampled at 2.5 m with one sample of length
tolerance so sparse and dense geometry agree.

At start and every accepted reroute the active route's exposure windows are
computed off the main actor, replaced rather than accumulated, and updated if
the camera set changes. Entries speak only for windows ahead within the alert
radius, while the camera is also within that radius of the vehicle. Passing
requires the vehicle to be inside the actual window and wedge at 35 m (25 m for
undirected cameras), not the banner's old 60 m escalation. Outside navigation,
the same predicate uses up to 16 recent fixes over 15 seconds, at least 10 m
of movement, a valid course agreeing with the track, and current in-view range.
The undirected 30 m stretch still applies. Only eligible, enabled device types
contribute to the two/three/several prompt. Missing/stale direction, poor fixes
or unbuilt route exposure fail silent. Track and windows stay in memory only.

This is geometry, not proof of optical line of sight: OSM camera tags contain no
reliable road association/elevation. Parallel roads, mis-tagged directions and
occlusion can still be wrong; genuinely undirected cameras may be missed. The
predicate remains separate so it can later be reused for other alert surfaces.
Banner, haptic, notification and Live Activity camera fields remain governed by
the existing Alert mode in exactly the same way during and outside navigation;
they do not use the speech predicate. Trip tally retains its existing behavior.
ALPR manufacturer or
brand tags containing "flock" select Flock recordings; other ALPRs and cameras,
speed cameras and gunshot detectors each have their own clips. Unknown devices
and guards stay silent. Rear entry alerts are silent; field-of-view alerts and
passing have specific clips. Ahead groups use the two/three/several recording.

Settings shows one master Voice switch, default on, and a "Voice & Spoken
Prompts" page that holds everything else. That page starts with a voice list:
two plain groups: Live (Easton and Harper, generated on the phone with street
names and exit numbers) and Recorded (Eric and Jessica, fixed clips without
street names). One selection spans all four rows; each keeps the existing
checkmark and preview button. Previews are explicit, work with Voice off, and
are refused while starting or navigating. Live previews show an error instead
of substituting another voice.

**Live speech.** Phonon 31m English runs through xn-ptts 0.7.1 in every build.
The verified Core ML bundle includes only Easton and Harper, copied intact by a
build phase. Runtime calls are local file install/load/render only; no model
fetch or telemetry exists in the app path. All supported phones get live speech,
without a RAM threshold. The selected engine never changes during a trip:
Easton and Harper never use recordings or system speech. A failed, late,
unavailable or critical-thermal live prompt is skipped silently; the map,
turn card and camera banners remain unchanged. Serious thermal state still
permits short speech bursts; critical skips. Eric and Jessica keep their
recorded-only behavior and existing system-speech last resort for unsupported
instructions. SpokenRoadName keeps route names/exit numbers in
memory only, with the same shared fixture rules; the text gate no longer needs
a word list. Unsupported names are omitted, not spoken in part.

PhononSpeechService eagerly plans all scheduled approaches, final actions,
lane/light variants and continue prompts for the current and next two steps.
Accepted reroutes replace this window. A FIFO worker renders one utterance at a
time through the engine's user-initiated queue; current-step work precedes generic
camera/arrival/reroute warm-up. A 64 MiB route PCM cache with a separate bounded camera PCM cache retains this window plus generic
common prompts; window replacement removes route text immediately and trip end
clears all text/audio, jobs and failures. A generation token rejects stale results.
Navigation startup and location updates never wait for speech. At trip start,
the opening is queued ahead of the entire render-ahead window and waits up to
eight seconds, including foreground model load. The initially suggested five
seconds proved marginal with per-voice first-load calibration in the simulator;
eight permits calibration plus the first short sentence, while dropping an
opening that is no longer useful. Ordinary guidance waits at most two seconds
from creation (roughly 60 m at highway speed), never indefinitely. A route/step
identity and latest-prompt token discard a waiting direction after step change,
reroute or supersession. Queued time counts against every deadline.

Camera alerts wait only within their existing five-second lifetime, then skip.
A camera preempts guidance still waiting for PCM, so it cannot spend two seconds
behind a model lookup. Active audio is not interrupted. All live utterances use the five-second audio
ceiling: the former three-second guidance cap discarded ordinary named
approaches even when already cached. Camera lifetime governs the camera, not the
length of otherwise valid guidance; a camera may expire behind playing audio.
For overlong named guidance, render-ahead lazily tries shorter variants: full,
then exit-number-only when applicable, then the generic prompt without a name or
exit number. Before rendering, a conservative character-count predictor selects the richest
variant expected to fit; a render that still exceeds five seconds immediately
queues its shorter variant ahead of ordinary render-ahead work. It preserves
lane/light sentences and the selected live voice. This avoids
tripling ordinary render work and cache pressure. Overlong PCM is discarded;
only its duration verdict remains for the route window. Shorter variants share
the existing PCM budget, route window, deadline and playback freshness identity.
Resolution chooses the first (most informative) fitting variant, without starting
a new deadline. If even generic speech is too long it still skips; unavailable
or late rendering also retains the existing silent-skip policy. The player never
holds audio focus while waiting. There is no same-gender mapping or recorded
length comparison in the live path; the clip loader also refuses live requests
without live PCM as a second barrier against accidental switching.

Each sentence is generated separately with seed 42, resampled by VoiceResampler,
trimmed, levelled with a fixed gain calibrated once per voice from a long generic
passage, peak-limited to 0.66 with the shared 1 ms attack/50 ms release, and joined
by VoicePCM.compose using VoiceTimeline.sentenceGap (350 ms) and 8 ms fades.
The fixed gain avoids pumping on short turns and names. Calibration uses mono
BS.1770 gated loudness targeting -16 LUFS; limiting may lower the achieved level.
No prompt text, road name or rendered audio is written to disk or logged.
Phonon uses VoicePromptPlayer, not its own player, so there is one audio session.
The arrival summary counts Phonon prompts requested/spoken/with names in memory.

The Debug Phonon page and bench remain for listening and timing only. Debug
metrics exports add bounded render wall time, foreground/background, success,
error type name (never description), deadline outcome and skip counts grouped by foreground/background and reason.
Each prompt also has a text-free timeline: random prompt/render IDs, kind,
application state, foreground/background, request/render times, resolution wait,
audio duration, cache hit, breaker state, variant label (full/numberOnly/nameFree)
and played/skipped outcome. Render-ahead
and playback share a random render ID, never a text hash. Timeline and render
rows append immediately to the existing session JSONL and recover after an app
kill, including past a truncated line. The same timeline goes to unified logging
under `speech.timeline`; only fixed labels, random IDs, counts and durations are
public. The DEBUG latency HUD shows live played/skipped totals and last skip
reason, even collapsed. These records have no text, clip key, road name, route
identity or coordinates. They are compiled out of Release with the existing
sentinel gate.

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

- **Driving motion buffers delivery jitter instead of restarting ease-outs.**
  MapKit's system user following has no public hook for substituting Ferrostar's
  snapped position; SwiftUI's user-location camera exposes heading and fallback,
  not a controllable follow distance/pitch. It therefore cannot satisfy snapped
  guidance and speed-based zoom. Independent linear camera/puck animations still
  cut corners and hand off unpredictably when fixes arrive early. Instead a
  retained `MKMapView` drives a non-animated camera from one interpolated pose
  each display tick. The puck is a screen overlay anchored to the camera center
  while following; when panned, that same overlay is projected through the map.
  This avoids MapKit's asynchronous annotation layout shaking the puck against
  the map. The display link requests the display's full refresh range, including
  ProMotion, rather than the former 20 fps cap; iOS chooses the actual rate.
  Path interpolation follows the route, or raw fixes off route. It buffers about
  two fix intervals rather than predicting beyond GPS. Monotonic arrival intervals, clamped to
  0.1-5 s, determine duration (slow movement may take several seconds to cross
  the location manager's 10 m distance filter); a gap over ten seconds restarts
  instead of sweeping across it. Small arrival changes are filtered, and a
  monotone cubic segment preserves velocity at handoff instead of stopping or
  jumping in speed. Heading takes the shortest arc through north. Route overlays and
  camera annotations update only with their data, never on each display tick.
  Warning views are limited to a 5 km margin, reconciled each kilometre, and
  the covered planner map is removed while driving instead of rendering twice.
  Panning/zooming disables follow; Re-center resumes it. The same Release-safe
  path handles real location updates and does not depend on debug simulation.
  Camera ownership is yielded at map touch-down by a passive recognizer that
  never recognizes, delays, cancels or prevents MapKit gestures. Recognizer
  states are also checked before each display-link camera write, rather than
  relying on a region callback that may be nested inside `setCamera`. Pan,
  pinch, rotation, pitch and double-tap zoom therefore work immediately, and
  follow stays off after the gesture ends. Re-center blends from the user's
  camera to the current speed-dependent follow camera over 0.8 seconds while
  keeping the puck projected on the car throughout the transition.
- **The driving zoom opens gradually with speed.** Distance stays at 450 m
  through 20 mph, then follows `450 + 1250 * ((mph - 20) / 50)^2`, capped at
  1700 m at 70 mph. This gives about 563 m at 35 mph and 763 m at 45 mph while
  leaving room to read highway junctions. Speed has a three-second exponential
  filter, a 70 m zoom-target dead band and a further 2.5-second distance ease;
  negative/nonfinite speeds are ignored. Pitch stays 45 degrees so speed changes
  do not tilt the map as well. Zoom state continues settling while follow is
  off but never overrides the user's camera until Re-center.

  Simulator validation uses system CoreLocation scenarios with the debug route
  simulator off, so it exercises the production adapter. On the iOS 18.2
  simulator, 35 one-second process CPU samples during Freeway Drive averaged
  23.99% for regular following and 22.45% for the driving screen after removing
  the covered planner map and using the 20 fps cap. City Run averaged 23.53%
  regular and 18.58% driving in the same sampling window. These are simulator-process
  numbers, not device battery or GPU measurements. Videos and scenario route
  fixtures stay local because they contain real map locations.

  A close-zoom follow-up found up to 3.17 points of vertical annotation motion
  in a constant-speed debug replay and 2.33 points on system location playback:
  MapKit's annotation layout and camera rendering were out of phase even though
  one callback supplied both coordinates. The screen-anchored overlay removes
  that path; measured follow-position variation is now zero at 15/35/70 mph.
  The former 20 fps cap also moved the ground about 1.6 m per tick at 70 mph.
  Native-rate requests measured about 16.65 ms median on a 60 Hz simulator;
  ProMotion is enabled with `CADisableMinimumFrameDurationOnPhone`, but iOS
  controls the actual rate under thermal/power/display constraints. The cost is
  explicit: close-zoom app CPU rose from roughly 18-23% to 27-29% in the same
  instrumented simulator windows. No lower frame cap is silently substituted.
  Delivery jitter is separately filtered, with about two intervals of buffering
  and velocity-matched monotone cubic handoffs. This trades additional display
  latency for steadier motion; route progress and prompt timing still use the
  newest fix and are not delayed by presentation.

- **Ferrostar rather than guidance written here.** Snapping, step advance
  on looping detours and deviation with accuracy gating are
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
  with `managesAudioSession: false`. `VoicePromptPlayer` confines audio and
  queue state to the main actor; synthesis runs off it on Phonon's serial
  user-initiated queue. It activates `.playback` / `.voicePrompt` with
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
- **Foreground warm-up, opportunistic background speech.** Core ML's Neural
  Engine behavior is unconfirmed on iOS 26. Apple's iOS 27 Background Inference
  entitlement requires continued-processing authorization for background ANE
  access; this app neither requests it nor assumes it can obtain approval.
  Phonon uses cpuAndNeuralEngine (never all/GPU), with its vocoder CPU-only.
  Loading and first compilation start only in the foreground at activation or
  trip start, only with a live voice selected and the master Voice switch on.
  An explicit live preview separately authorizes warm-up even with Voice off.
  Installation and the synchronous C load run on an app-owned user-initiated
  actor executor, not the main actor or an unchecked upstream work queue.
  UIKit's active state and cancellation are checked immediately before
  dispatch, then a lifecycle generation grant is rechecked on that executor
  before both install and load. Already-running Core ML work cannot be forcibly
  interrupted, but revoked queued work never starts. If unloaded while locked,
  speech is skipped rather than loading or compiling. The warmed engine stays loaded across trips so a
  later background prompt needs no load. Foreground eagerly renders the whole
  upcoming window; background still attempts user-initiated renders, never
  background-QoS work. Three consecutive background errors or playback deadline
  misses open a pure circuit breaker. After sixty seconds one probe may run;
  success closes it, failure starts another cooldown, and foreground activation
  closes it immediately. Rendering
  uses one attempt identity for deadline and completion accounting, so a late
  error cannot count the same attempt twice. The active render key is excluded
  from the queue; success and failure both validate the route window before
  storing anything, including failed-name records. An unchanged exact key is accepted even when
  the window advances. Every waiting playback request owns its own deadline
  identity; a miss counts according to foreground state at expiry, even while
  queued behind a slow render. Completion suppresses an already-counted miss. Cached PCM
  remains usable when the breaker is open. No foreground/background reload or
  speculative CPU switch occurs. A locked-phone drive on the actual supported
  OS/device is what settles whether background live speech works; until then,
  silent skips and text-free Debug counts expose failure, rather than hiding
  missing ANE permission behind a different voice.
  Sources: Apple's Background Inference entitlement documentation and WWDC22
  session 10027, plus the pinned runtime's Core ML driver.
- **Tests must not leave OS-owned Live Activities.** Production activity
  creation, ownership transfer and foreground/background behavior are unchanged.
  Navigation and tracking tests inject `LiveActivityManager` with
  `activityRequestsEnabled: false`, including the Debug app host launched by
  the test scheme or local UI tests. Synthetic-drive teardown awaits cleanup.
  This avoids an orphan activity's relaunch racing XCTest's instrumented launch
  after simulator reboot; changing user-visible Live Activity behavior is not
  a test fix.
- **Drive simulation is debug-only.** `Simulate drive` under the route card has
  15/25/35/45/55/70 mph Speed presets and a 1x/2x/4x/8x Time multiplier, persisted
  only in Debug and applied on the next Start. At 1x a fix arrives each second;
  the distance per simulated second is mph converted to m/s. Ferrostar's provider
  only densifies geometry, advances one vertex per tick, and supplies no speed,
  so `DebugDriveLocationProvider` first makes uniform path-distance samples and
  wraps the provider. It stamps configured speed and timestamps advancing by
  path travel time, retaining its forward course. A time multiplier compresses
  wall time without multiplying speed or the simulated clock. All controls,
  settings keys and implementation live inside `#if DEBUG`; Release has none.
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

### Exposure counts and locked speech diagnostics

The route card, camera speech and trip counts use the same
CameraObservability.RouteExposure windows. Route choice does not: the planner
keeps scoring any camera within 35 m of a candidate, regardless of facing unless
FOV avoidance is on, so avoidance stays conservative and planning cost is
unchanged. Physical exclusion polygons keep their original full-circle behavior.
The route card can therefore show fewer cameras than the planner avoided. Counts mean unique cameras whose
observable window the car actually traversed, not the nearest camera inside a
200 m banner radius. Navigation has its own tally (including ALPR/speed/other),
while the map trip tally uses the same rule and the course-based predicate when
not navigating. Banners, haptics, notifications and Live Activity camera fields
retain their radius/Alert mode behavior. A planned count is a forecast: leaving
the route, disabled speech or ending early can legitimately change actual or
spoken totals. Exposure remains a geometric estimate, not proof of line of sight.

Navigation seeds exposure with the planner's corridor cameras and merges nearby
updates without discarding the seed. Per-route DEBUG camera diagnostics use
ordinals along the route, never OSM IDs or coordinates: exposed, eligibility,
entry/pass requested, played/skipped, and route-ended-before-entry. Nearby but
not exposed is a separate count. These append to session JSONL and unified log;
the HUD shows exposed/spoken unique ordinals. IDs and coordinates stay in memory.

Loaded speech renders are not cancelled by an inactive transition. The opening
owns the audio queue until completion; schedule updates wait rather than create
an already-expiring direction behind it. Fixed camera sentences use their own
bounded cache so a protected named-guidance window cannot starve them, and an
on-demand camera request moves ahead of ordinary render-ahead. Continue-distance
rounding variants are planned too, because the first fix may enter a step late.
Stored step banners drive both planning and playback, avoiding text-key drift.
The 24-render synthetic length fit is 0.8101 + 0.05352 * characters + 0.35 per
extra sentence, with 0.65 seconds of safety margin. The existing field timeline
has no text lengths, so it cannot validate prediction error; new DEBUG render
rows include only counts/prediction, never text, for a future measured comparison.
