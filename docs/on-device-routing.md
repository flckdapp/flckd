# On-device routing

Routing runs on the phone. There's no hosted routing path and no network
fallback. The tile pipeline that produces the road data lives in
[`server/`](../server/README.md); this note covers the app side.

---

## The rule

No coordinate leaves the device for routing: not the start, not the
destination, not the camera positions being avoided. The route planner has
no endpoint to call and it works in airplane mode.

A hosted routing service has to be told where you are and where you're
going. For an app whose purpose is warning people about surveillance,
sending those coordinates to a third party isn't acceptable, so the network
routing path was removed rather than made optional. There's no setting for
it and nothing a future refactor or remote config could switch back on.

This is about route data, not about being offline in general. Map tiles
still come from Apple, and camera data still comes from DeFlock's CDN and
from Overpass. Those requests reveal roughly what you're looking at; a
routing request would reveal where you're going.

---

## The engine

The app embeds Valhalla through
[`rallista/valhalla-mobile`](https://github.com/rallista/valhalla-mobile)
(MIT), pinned to 0.6.3. It's the only maintained iOS build of a full routing
engine, it passes raw Valhalla JSON straight through so camera avoidance
works with the package unmodified, and its responses have the same shape as
the HTTP API, so the request builder and parser in `ValhallaRoutingService`
didn't need to change when the network path was removed.

0.6.3 embeds Valhalla 3.6.3, which is why the tile service is pinned to
3.6.3 as well. Tiles are memory-mapped binary structures, so writer and
reader must agree exactly. A mismatch can produce wrong routes rather than
errors, so `TilePackService` refuses a manifest that reports any other
version.

`LocalValhallaEngine` owns the one long-lived engine instance. If you touch
it, these are the parts that matter:

- **Threading.** The routing call is synchronous and blocking, and the
  engine serialises calls internally. All native calls run on a dedicated
  serial `DispatchQueue`, bridged into async/await with a continuation.
  Never call the engine from a Swift actor or the main thread.
- **Lifetime.** The engine is built lazily on first use (mmap, index parse,
  tzdata extraction) and torn down on `didEnterBackground` and on memory
  warnings. It rebuilds on the next request. Construction was measured at
  72 ms on an A18 and 99 ms on an A14 against a 455 MB pack, so a rebuild is
  cheap next to a plan, which takes several hundred milliseconds per engine
  call. Turn-by-turn should still skip the background teardown while
  navigating, but the cost of getting it wrong is small.
- **Cache size.** The package's default config sets a 1 GB tile cache,
  which is a server setting and costs about 15 MB of dirty memory at
  construction. The app sets it to 32 MB.
- **Exclusion limits.** Valhalla's default service limits cap the total
  perimeter of all `exclude_polygons` at roughly 10 km, which is about 50
  camera circles at 30 m radius. Aggressive avoidance fences hundreds of
  cameras at up to 100 m, so the app raises `maxExcludePolygonsLength` to
  1,000 km in the engine config.
- **Errors.** Valhalla codes 442 (no path) and 171 (no suitable edges) both
  mean the exclusion set is too aggressive. They're mapped to
  `RoutingError.noRouteFound` so `routeWithProgressiveAvoidance` can retry
  with a looser set.

---

## Region packs

`TilePackService` reads `/v1/manifest.json` from the configured server
(default `https://tiles.flckd.app`, editable in Settings → Offline Routing),
checks `schema` and `valhalla_version`, and downloads a pack part by part,
verifying each part's SHA-256 as it arrives and the whole file's SHA-256 at
the end. Packs are stored under
`Application Support/valhalla/regions/<id>.tar` with a small JSON sidecar
describing what was installed, and the directory is flagged as excluded
from backup.

Why that location:

- Not `Documents`, because iCloud would try to back up gigabytes and App
  Review objects to that.
- Not `Caches`, because the system can delete a file there while it's
  memory-mapped and in use.
- Not On-Demand Resources, because those are fixed at build time and every
  monthly data update would need a new app submission.

The tar is never unpacked. Valhalla reads it in place. The tile service
checks the internal layout before publishing, so a pack that arrives intact
is usable as-is.

`RegionStore` picks the pack to route with: the smallest installed region
whose bounds contain both endpoints, or the largest installed region when
no coordinates are known yet. `USStateBounds` holds rough bounding boxes
for each region the server offers, used only for preflight UX like "is the
destination's state downloaded?". Routing correctness never depends on
those boxes; the server cuts packs from real Geofabrik boundary polygons.

**When there's no pack.** If nothing covers the route, the planner says so
and offers the download. If start and destination fall in different
regions, it says which pack is missing. It never asks a server instead.

**Plain HTTP.** App Transport Security is opened only for local network
addresses and `*.ts.net`, so a home server or a Tailscale node works
without a certificate. Use the MagicDNS name for Tailscale, not the raw IP;
ATS exceptions are domain-based. Any other HTTP address is refused.

---

## Cost

**App size: about 15 MB installed.** Measured from the shipped 0.6.3
binary: roughly 13.4 MB of code and data plus a 1.5 MB timezone resource.
The App Store download increase is smaller, likely 6–8 MB, but that needs
confirming in App Store Connect. 0.6.3 more than halved the binary compared
with 0.6.2.

**Memory.** Tiles are mapped read-only and shared, so they're clean,
evictable pages. A 200 MB region doesn't cost 200 MB of memory. The fixed
cost is about 8.6 MB for the tile index, plus the 32 MB cache ceiling.

**Download size per state.** Which regions are published, how big each one
is, and when it was built is shown at
[tiles.flckd.app](https://tiles.flckd.app), which reads the same manifest
the app does. For scale: a mid-sized state is a few hundred megabytes, the
largest states are 1–2 GB, and the whole US would be 15–20 GB, which is why
the app offers states rather than the whole country.

---

## Alternatives considered

| Option | Verdict |
|---|---|
| **valhalla-mobile** | Chosen. Maintained, MIT, camera avoidance works unmodified. |
| Custom A\* over raw OSM data | Smaller data (~40–80 MB per state) and penalties are natural, but months of work and a routing engine to maintain forever. |
| libosmscout | Works, but avoidance needs C++ changes to the router. |
| Organic Maps engine | Production-proven, but tied to their own map format. Useful as reference, not as a dependency. |
| Mapbox Navigation SDK | Can't avoid arbitrary points, sends route data to Mapbox, and costs per user. |
| OSRM | Needs 2–4 GB of RAM for one state. Not viable on a phone. |
| GraphHopper | Needs a JVM. The iOS port was abandoned in 2021. |

---

## Open questions

- Real pack sizes and the real App Store download increase are unmeasured.
- App Review's view of a 1.8 GB in-app download is unknown. Offering
  metro-sized regions instead of whole states would sidestep it, and the
  tile service can already cut arbitrary regions.
- The widget target must not link the Valhalla package. It doesn't route
  and would pay the size cost for nothing.

---

## Related

- [`server/README.md`](../server/README.md): how the road data is built and served
- [`PRIVACY.md`](../PRIVACY.md): what this means for users
- [`ARCHITECTURE.md`](../ARCHITECTURE.md): where routing sits in the app
