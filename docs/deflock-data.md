# DeFlock data: licence and usage

The app reads camera data from two DeFlock endpoints: the bulk tiles at
`https://cdn.deflock.me/regions/` and the Overpass instance at
`https://overpass.deflock.org/api/interpreter`. This note records what the
licence requires and how the app is expected to behave as a client. Checked
2026-09-01.

---

## Licence

The camera locations are OpenStreetMap data (nodes tagged
`man_made=surveillance`), so the dataset is under the ODbL 1.0, © OpenStreetMap
contributors. DeFlock's data repository says so directly, and its own
pipeline code is MIT. DeFlock's Terms of Service describe the site as
providing access to map data sourced from OpenStreetMap under OSM's terms.
DeFlock adds no licence layer of its own; the ODbL passes straight through to
us.

DeFlock has no formal API terms for either endpoint. Its data repository
README says anyone can use the data with no API key and no rate limits beyond
Cloudflare's defaults, which is the clearest statement of intent from the
maintainers. The Terms of Service prohibit OSM vandalism, scraping in
violation of OSM's terms, impersonation, and commercial products without
proper attribution or ODbL compliance. A free app with OSM attribution is
fine. DeFlock's own mobile app uses `overpass.deflock.org` as its default
endpoint, and other third-party projects already consume the published
tiles.

Contact: `contact@deflock.org`. A one-line heads-up that FLCKD uses the
endpoints would be a courtesy, so they can reach us if usage patterns ever
need to change.

---

## Attribution we owe

Per the OSMF attribution guidelines:

- Show "© OpenStreetMap contributors" where the camera data is displayed, in
  the map corner or in an easily found About or Credits screen, linking to
  https://www.openstreetmap.org/copyright.
- State that the data is under the ODbL. The osm.org/copyright link covers
  this.

Suggested credit line:

> Camera data © OpenStreetMap contributors (ODbL), via DeFlock (deflock.me)

Crediting DeFlock isn't legally required but matches their ToS expectation
and is the decent thing to do.

Share-alike only bites if we ever redistribute an enhanced or merged camera
database. Displaying pins in the app is a "produced work" and needs only the
attribution above.

---

## Being a polite client

**CDN tiles.**

- Fetch `regions/index.json` and honour its `expiration_utc`. Data refreshes
  roughly hourly; don't re-poll before the index says to.
  `DeFlockCDNService` does this.
- Use the `tile_url` template from the index, including the `?v=<epoch>`
  cache-buster, rather than hard-coding paths.
- Use conditional requests. The CDN returns strong ETags and honours
  `If-None-Match` (verified: 304 responses), and serves
  `Cache-Control: max-age=300`.
- Tiles are large (a 20° tile can be around 8 MB), so cache on disk, fetch
  only the tiles covering the map area, and accept gzip.

**Overpass.**

- Keep queries viewport-bounded with a sensible `[timeout:…]`. Use the CDN
  tiles for anything wide-area.
- One request in flight at a time, back off on 429 and 504, and fall back to
  cached data on failure. `OverpassService` does this.

**Both.** Send a descriptive User-Agent. The app sends
`FLCKD/1.0 (iOS; +https://flckd.app)`, which identifies the app and where to
find it without identifying the user. This is mandatory on OSMF's own
servers and courteous everywhere else.

---

## Sources

- https://github.com/FoggedLens/deflock-data: README licence section and
  the "anyone can use the data" statement
- https://github.com/FoggedLens/deflock: `TermsOfService.vue`
  (deflock.org/terms) and the `alpr_cache` generator for `regions/index.json`
- https://github.com/FoggedLens/deflock-app: default Overpass endpoint in
  `lib/services/overpass_service.dart`
- https://www.openstreetmap.org/copyright
- https://osmfoundation.org/wiki/Licence/Attribution_Guidelines
- https://opendatacommons.org/licenses/odbl/
