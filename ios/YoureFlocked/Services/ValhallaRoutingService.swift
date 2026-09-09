import Foundation
import CoreLocation
import os

/// User-selectable avoidance aggressiveness. Higher levels exclude more
/// cameras with bigger keep-away radii, trading longer side-street routes
/// for fewer camera passes. Backed by the route planner's slider.
enum AvoidanceLevel: Int, CaseIterable, Sendable {
    case low = 0
    case balanced = 1
    case high = 2
    case max = 3

    /// Maximum number of corridor cameras turned into exclude polygons.
    var maxExclude: Int {
        switch self {
        case .low: return 25
        case .balanced: return 150
        case .high: return 500
        case .max: return 2000
        }
    }

    /// Keep-away radius around each camera, in meters.
    var radiusMeters: Double {
        switch self {
        case .low: return 20
        case .balanced: return 35
        case .high: return 60
        case .max: return 100
        }
    }

    var label: String {
        switch self {
        case .low: return "Low"
        case .balanced: return "Balanced"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}

actor ValhallaRoutingService {

    /// Per-rung planning trace. Counts, radii and OSM camera IDs are public;
    /// coordinates never are (PRIVACY.md), so field logs stay shareable.
    private static let log = Logger(subsystem: "io.vws.app.flckd", category: "routing")

    /// Fixed radius used to score how many cameras can see a route.
    /// Deliberately independent of AvoidanceLevel: the level changes how hard
    /// we try to route around cameras, not how "seeing a camera" is measured.
    /// A fixed yardstick keeps camera counts comparable across slider levels.
    /// 35 m matches RouteView's cameraBufferMeters so the engine's candidate
    /// choice and the card's "Cameras" stat always agree.
    static let scoringRadiusMeters: Double = 35

    /// Caps on the greedy re-fencing pass that runs after an endpoint had to
    /// be unfenced (see `routeWithProgressiveAvoidance`). Each refinement is
    /// one more engine call, so both a per-rung and a whole-request budget
    /// keep an encircled destination from turning into dozens of requests.
    static let maxRefinementCallsPerRung = 6
    static let maxRefinementCallsTotal = 12

    /// Search radii handed to Valhalla for both endpoints once exact snapping
    /// fails, tried smallest first. Exclusion is per graph edge: a parking
    /// aisle mapped as one long OSM way is a single edge, so a fence around a
    /// camera at its entrance removes the whole aisle, pin included, and the
    /// request is infeasible even when a neighbouring aisle is reachable with
    /// no cameras. `radius` lets Loki treat every edge within this distance
    /// as an endpoint candidate, so the route can end on that aisle instead
    /// of dropping camera fences to reach the exact edge. Ending a few dozen
    /// metres from the pin is preferable to unfencing a camera, so these
    /// steps precede unfencing. The larger radius matters: a smaller one may
    /// reach only the street in front of a destination whose driveway is the
    /// fenced camera itself.
    static let endpointSnapRadiiMeters: [Double] = [60, 120]

    /// On-device only. There is no network routing path and no fallback:
    /// docs/on-device-routing.md and PRIVACY.md promise that no coordinate
    /// leaves the device for routing, so no transport belongs here.
    func route(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        avoiding cameras: [SurveillanceCamera],
        useFOV: Bool = false,
        costing: String = "auto",
        level: AvoidanceLevel = .balanced,
        scoringCameras: [SurveillanceCamera]? = nil,
        radiusOverride: Double? = nil,
        snapRadiusMeters: Double = 0
    ) async throws -> ValhallaRoute {
        guard LocalValhallaEngine.shared.hasRegion else {
            throw RoutingError.engineUnavailable
        }
        let request = buildRequest(from: start, to: end, avoiding: cameras, useFOV: useFOV, costing: costing, level: level, radiusOverride: radiusOverride, snapRadiusMeters: snapRadiusMeters)
        let jsonData = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw RoutingError.invalidResponse
        }
        let region = RegionStore.bestAvailableRegion(containing: [start, end])
        let data = try await LocalValhallaEngine.shared.route(rawRequest: json, region: region)
        // Valhalla may return alternates. Every candidate already respects the
        // exclude polygons, so pick the one with the fewest cameras actually
        // near its path, tie-broken by shortest distance.
        let candidates = try parseCandidates(data)
        return bestCandidate(candidates, scoredAgainst: scoringCameras ?? cameras, level: level, useFOV: useFOV)
    }

    /// Times a plan and publishes the result to `RoutingMetricsStore`.
    /// Routing behaviour is unchanged; measurement is a side effect.
    func routeWithProgressiveAvoidance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        cameras: [SurveillanceCamera],
        useFOV: Bool = false,
        costing: String = "auto",
        level: AvoidanceLevel = .balanced,
        trigger: RoutePlanSample.Trigger = .initial,
        speedMps: Double? = nil
    ) async throws -> (route: ValhallaRoute, avoidedCount: Int, totalCount: Int) {
        let watch = Stopwatch()
        let metrics = RoutePlanAccumulator()

        func publish(route: ValhallaRoute?, exposure: Int, failure: String?) async {
            let sample = RoutePlanSample(
                id: UUID(),
                timestamp: Date(),
                trigger: trigger,
                level: level.label,
                totalMs: watch.elapsedMs,
                engineMsTotal: metrics.engineMsTotal,
                engineMsMax: metrics.engineMsMax,
                scoringMsTotal: metrics.scoringMsTotal,
                engineBuildMs: metrics.engineBuildMs,
                engineCalls: metrics.engineCalls,
                refinementCalls: metrics.refinementCalls,
                candidatesScored: metrics.candidatesScored,
                corridorCameras: metrics.corridorCameras,
                fencedCameras: metrics.fencedCameras,
                resultExposure: exposure,
                routeKm: route?.distanceKm ?? 0,
                routeMinutes: (route?.timeSeconds ?? 0) / 60,
                speedMps: speedMps,
                thermalState: ProcessInfo.processInfo.thermalState.exportName,
                failure: failure
            )
            await MainActor.run { RoutingMetricsStore.shared.record(sample) }
        }

        do {
            let result = try await planProgressiveAvoidance(
                from: start, to: end, cameras: cameras,
                useFOV: useFOV, costing: costing, level: level, metrics: metrics
            )
            await publish(
                route: result.route,
                exposure: max(0, result.totalCount - result.avoidedCount),
                failure: nil
            )
            return result
        } catch {
            await publish(route: nil, exposure: 0, failure: String(describing: error))
            throw error
        }
    }

    private func planProgressiveAvoidance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        cameras: [SurveillanceCamera],
        useFOV: Bool,
        costing: String,
        level: AvoidanceLevel,
        metrics: RoutePlanAccumulator
    ) async throws -> (route: ValhallaRoute, avoidedCount: Int, totalCount: Int) {
        let corridorCameras = camerasInCorridor(from: start, to: end, cameras: cameras, bufferKm: 5.0)

        let relevantCameras: [SurveillanceCamera]
        if useFOV {
            relevantCameras = corridorCameras.filter { camera in
                guard !camera.directions.isEmpty else { return true }
                let routeBearing = SurveillanceCamera.bearing(from: camera.coordinate, to: start)
                let destBearing = SurveillanceCamera.bearing(from: camera.coordinate, to: end)
                return camera.directions.contains { entry in
                    var delta1 = routeBearing - entry.center
                    while delta1 > 180 { delta1 -= 360 }
                    while delta1 < -180 { delta1 += 360 }
                    var delta2 = destBearing - entry.center
                    while delta2 > 180 { delta2 -= 360 }
                    while delta2 < -180 { delta2 += 360 }
                    return abs(delta1) <= 90 || abs(delta2) <= 90
                }
            }
        } else {
            relevantCameras = corridorCameras
        }

        let totalCount = corridorCameras.count
        metrics.corridorCameras = totalCount

        // Cameras closest to the direct start-to-end line matter most; the
        // exclusion set is the nearest `maxExclude` of them.
        let sorted = sortedByCorridorProximity(relevantCameras, from: start, to: end)
        let capped = Array(sorted.prefix(level.maxExclude))
        metrics.fencedCameras = capped.count

        // Radius ladder: every avoidance level evaluates its own radius and
        // all smaller levels' radii. Combined with the shared candidate pool
        // below, a higher level's pool is a superset of a lower level's, so
        // raising the slider can never produce a worse route.
        let ladder = AvoidanceLevel.allCases
            .map(\.radiusMeters)
            .filter { $0 <= level.radiusMeters }
            .sorted(by: >)

        // Endpoint relaxation ladder, tried in order until a rung is feasible.
        // When the destination (or origin) is encircled, meaning every access
        // road passes within the keep-away radius of some camera, the request
        // is infeasible. First relax the endpoint rather than the fences: let
        // it snap to any edge within `endpointSnapRadiiMeters`, which rescues
        // the common case where the fence around an entrance camera swallowed
        // the one long edge the pin sits on. Only then stop fencing the
        // cameras nearest the endpoints, which are unavoidable anyway.
        // Halving the corridor set instead would throw away mid-corridor
        // avoidance while keeping the ring that caused the failure. Unfencing
        // a whole ring is still coarse, so the greedy re-fencing pass in the
        // rung loop narrows it back down to the cameras that are truly
        // unavoidable.
        let widestSnap = Self.endpointSnapRadiiMeters.max() ?? 0
        let relaxations: [(unfence: Double, snap: Double)] =
            [(0, 0)]
            + Self.endpointSnapRadiiMeters.map { (0, $0) }
            + [250, 600, 1600].map { ($0, widestSnap) }

        func endpointDistance(_ camera: SurveillanceCamera) -> Double {
            let location = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
            let toStart = location.distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
            let toEnd = location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            return min(toStart, toEnd)
        }

        // Shared candidate pool. Every rung contributes its primary route and
        // alternates, and the plain no-avoidance route is always included so
        // avoidance can never do worse than doing nothing. All candidates are
        // scored with the same fixed yardstick; the winner has the fewest
        // cameras that can actually see it, tie-broken by fastest travel time.
        var pool: [(route: ValhallaRoute, exposure: Int)] = []
        func admit(_ routes: [ValhallaRoute], tag: String) {
            let scoringWatch = Stopwatch()
            defer { metrics.addScoring(scoringWatch.elapsedMs, candidates: routes.count) }
            for candidate in routes {
                let exposed = exposedCameraIDs(route: candidate, cameras: corridorCameras, radiusMeters: Self.scoringRadiusMeters, useFOV: useFOV)
                pool.append((candidate, exposed.count))
                Self.log.info("plan \(tag, privacy: .public): \(Int(candidate.timeSeconds))s \(candidate.distanceKm, format: .fixed(precision: 1))km exposure=\(exposed.count) ids=\(exposed.sorted().map(String.init).joined(separator: ","), privacy: .public)")
            }
        }
        Self.log.info("plan start level=\(level.label, privacy: .public) corridor=\(corridorCameras.count) fenced=\(capped.count)")

        if let baseline = try? await routeCandidates(from: start, to: end, avoiding: [], useFOV: useFOV, costing: costing, level: level, radiusOverride: nil, metrics: metrics) {
            admit(baseline, tag: "baseline")
        }

        var refinementBudget = Self.maxRefinementCallsTotal

        rungLoop: for radius in ladder {
            for (unfence, snap) in relaxations {
                let ring = unfence <= 0 ? [] : capped.filter { endpointDistance($0) <= unfence }
                let ringIDs = Set(ring.map(\.id))
                let subset = capped.filter { !ringIDs.contains($0.id) }
                if subset.isEmpty { break }
                let routes: [ValhallaRoute]
                do {
                    routes = try await routeCandidates(from: start, to: end, avoiding: subset, useFOV: useFOV, costing: costing, level: level, radiusOverride: radius, snapRadiusMeters: snap, metrics: metrics)
                } catch RoutingError.noRouteFound {
                    Self.log.info("plan r=\(Int(radius)) unfence=\(Int(unfence)) snap=\(Int(snap)) fenced=\(subset.count): no route")
                    continue // still encircled; relax further
                } catch {
                    Self.log.error("plan r=\(Int(radius)) unfence=\(Int(unfence)) snap=\(Int(snap)): \(error.localizedDescription, privacy: .public)")
                    break rungLoop // engine-level failure; stop probing
                }
                admit(routes, tag: "r=\(Int(radius)) unfence=\(Int(unfence)) snap=\(Int(snap)) fenced=\(subset.count)")

                // Greedy re-fencing. The ring unfence made the request
                // feasible by dropping every camera near an endpoint, which
                // also frees the engine to approach through the busiest
                // entrance, even when a quieter one exists.
                // Put the unfenced cameras the route actually passes back
                // one at a time, farthest from the endpoint first since
                // those are the most likely to be avoidable. A camera whose
                // re-fencing makes the request infeasible is genuinely
                // unavoidable and stays unfenced. Every feasible trial joins
                // the pool, so the fewest-cameras pick below sees them all.
                if !ring.isEmpty {
                    var unfenced = Dictionary(ring.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    var locked = Set<Int64>()
                    var primary = routes[0]
                    var rungCalls = 0
                    while rungCalls < Self.maxRefinementCallsPerRung, refinementBudget > 0 {
                        let hits = exposedCameraIDs(route: primary, cameras: Array(unfenced.values), radiusMeters: Self.scoringRadiusMeters, useFOV: useFOV)
                        let candidates = hits.subtracting(locked).compactMap { unfenced[$0] }
                        guard let target = candidates.max(by: { endpointDistance($0) < endpointDistance($1) }) else {
                            break // the route passes no unfenced camera; nothing left to gain
                        }
                        let trial = capped.filter { unfenced[$0.id] == nil || $0.id == target.id }
                        rungCalls += 1
                        refinementBudget -= 1
                        do {
                            let refined = try await routeCandidates(from: start, to: end, avoiding: trial, useFOV: useFOV, costing: costing, level: level, radiusOverride: radius, snapRadiusMeters: snap, metrics: metrics, isRefinement: true)
                            unfenced.removeValue(forKey: target.id)
                            admit(refined, tag: "r=\(Int(radius)) unfence=\(Int(unfence)) snap=\(Int(snap)) refenced=\(target.id)")
                            primary = refined[0]
                        } catch RoutingError.noRouteFound {
                            locked.insert(target.id) // unavoidable at this radius
                            Self.log.info("plan r=\(Int(radius)) refence \(target.id): no route, camera unavoidable")
                        } catch {
                            break rungLoop
                        }
                    }
                }
                continue rungLoop // rung satisfied; next radius
            }
        }

        guard let best = pool.min(by: { a, b in
            if a.exposure != b.exposure { return a.exposure < b.exposure }
            return a.route.timeSeconds < b.route.timeSeconds
        }) else {
            // Nothing routable at all: surface the plain attempt's error.
            let route = try await route(from: start, to: end, avoiding: [], costing: costing)
            let onRoute = exposureCount(route: route, cameras: corridorCameras, radiusMeters: Self.scoringRadiusMeters, useFOV: useFOV)
            return (route: route, avoidedCount: totalCount - onRoute, totalCount: totalCount)
        }

        Self.log.info("plan winner: \(Int(best.route.timeSeconds))s exposure=\(best.exposure) of \(totalCount) corridor cameras")
        return (route: best.route, avoidedCount: totalCount - best.exposure, totalCount: totalCount)
    }

    /// Runs one routing request and returns every candidate (primary plus
    /// alternates) without picking a winner. The progressive-avoidance loop
    /// accumulates these into a shared pool and scores them itself.
    private func routeCandidates(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        avoiding cameras: [SurveillanceCamera],
        useFOV: Bool,
        costing: String,
        level: AvoidanceLevel,
        radiusOverride: Double?,
        snapRadiusMeters: Double = 0,
        metrics: RoutePlanAccumulator? = nil,
        isRefinement: Bool = false
    ) async throws -> [ValhallaRoute] {
        guard LocalValhallaEngine.shared.hasRegion else {
            throw RoutingError.engineUnavailable
        }
        let request = buildRequest(from: start, to: end, avoiding: cameras, useFOV: useFOV, costing: costing, level: level, radiusOverride: radiusOverride, snapRadiusMeters: snapRadiusMeters)
        let jsonData = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw RoutingError.invalidResponse
        }
        let region = RegionStore.bestAvailableRegion(containing: [start, end])
        #if DEBUG
        dumpRequest(json)
        #endif
        let watch = Stopwatch()
        do {
            let (data, timing) = try await LocalValhallaEngine.shared.routeTimed(rawRequest: json, region: region)
            metrics?.addEngineCall(timing, isRefinement: isRefinement)
            return try parseCandidates(data)
        } catch {
            // A rejected rung still burned engine time, and the no-route rungs
            // are the expensive ones. Dropping them would flatter the totals.
            metrics?.addEngineCall(
                EngineTiming(buildMs: nil, callMs: watch.elapsedMs),
                isRefinement: isRefinement
            )
            throw error
        }
    }

    #if DEBUG
    /// Debug builds only: writes every engine request to
    /// tmp/flckd-plan/<n>.json so a failing plan can be replayed verbatim
    /// against a desktop Valhalla. Not compiled into release builds: the
    /// files contain the route endpoints.
    private var dumpCounter = 0
    private func dumpRequest(_ json: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flckd-plan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dumpCounter += 1
        try? json.write(to: dir.appendingPathComponent(String(format: "%03d.json", dumpCounter)), atomically: true, encoding: .utf8)
    }
    #endif

    /// Sorts cameras by perpendicular distance to the straight start-to-end
    /// line (planar approximation), nearest first.
    private func sortedByCorridorProximity(
        _ cameras: [SurveillanceCamera],
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> [SurveillanceCamera] {
        let midLat = (start.latitude + end.latitude) / 2
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(midLat * .pi / 180)
        let ax = start.longitude * mPerDegLon, ay = start.latitude * mPerDegLat
        let bx = end.longitude * mPerDegLon, by = end.latitude * mPerDegLat
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        func distSq(_ c: SurveillanceCamera) -> Double {
            let px = c.longitude * mPerDegLon, py = c.latitude * mPerDegLat
            let t = lenSq > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq)) : 0
            let cx = ax + t * dx, cy = ay + t * dy
            return (px - cx) * (px - cx) + (py - cy) * (py - cy)
        }
        return cameras.map { ($0, distSq($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    // MARK: - Request Building

    private func buildRequest(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        avoiding cameras: [SurveillanceCamera],
        useFOV: Bool,
        costing: String,
        level: AvoidanceLevel = .balanced,
        radiusOverride: Double? = nil,
        snapRadiusMeters: Double = 0
    ) -> [String: Any] {
        let radius = radiusOverride ?? level.radiusMeters
        var locations: [[String: Any]] = [
            ["lat": start.latitude, "lon": start.longitude, "type": "break"],
            ["lat": end.latitude, "lon": end.longitude, "type": "break"],
        ]
        if snapRadiusMeters > 0 {
            // Every edge within this distance is an endpoint candidate; see
            // `endpointSnapRadiiMeters`. Valhalla still prefers the nearest
            // reachable one, so exact-snap results are unchanged when the
            // pin's own edge is routable.
            for i in locations.indices { locations[i]["radius"] = snapRadiusMeters }
        }
        var request: [String: Any] = [
            "locations": locations,
            "costing": costing,
            "directions_options": ["units": "kilometers"],
            // Ask for alternates so we can pick the shortest route that still
            // meets the avoidance criteria. Valhalla caps this at its
            // service-limit (2 by default); ignored when unsupported.
            "alternates": 2,
        ]

        if !cameras.isEmpty {
            let limited = Array(cameras.prefix(level.maxExclude))
            let polygons = limited.map { camera in
                if useFOV, let dir = camera.direction {
                    return cameraWedgePolygon(
                        lat: camera.latitude, lon: camera.longitude,
                        directionDeg: dir,
                        halfAngleDeg: camera.directions.first?.halfAngle ?? 35,
                        radiusMeters: radius
                    )
                } else {
                    return cameraCirclePolygon(
                        lat: camera.latitude, lon: camera.longitude,
                        radiusMeters: radius
                    )
                }
            }
            request["exclude_polygons"] = polygons
        }

        return request
    }

    private func cameraCirclePolygon(lat: Double, lon: Double, radiusMeters: Double) -> [[Double]] {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * cos(lat * .pi / 180))
        var ring: [[Double]] = []
        for i in 0...8 {
            let angle = Double(i) / 8.0 * 2 * .pi
            ring.append([lon + lonDelta * cos(angle), lat + latDelta * sin(angle)])
        }
        return ring
    }

    private func cameraWedgePolygon(lat: Double, lon: Double, directionDeg: Double, halfAngleDeg: Double, radiusMeters: Double) -> [[Double]] {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * cos(lat * .pi / 180))
        let dirRad = (90 - directionDeg) * .pi / 180
        let halfRad = halfAngleDeg * .pi / 180
        let startAngle = dirRad - halfRad
        let endAngle = dirRad + halfRad

        var ring: [[Double]] = [[lon, lat]]
        let arcSegments = 6
        for i in 0...arcSegments {
            let angle = startAngle + (endAngle - startAngle) * Double(i) / Double(arcSegments)
            ring.append([lon + lonDelta * cos(angle), lat + latDelta * sin(angle)])
        }
        ring.append([lon, lat])
        return ring
    }

    private func camerasInCorridor(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        cameras: [SurveillanceCamera],
        bufferKm: Double
    ) -> [SurveillanceCamera] {
        let minLat = min(start.latitude, end.latitude) - bufferKm / 111.0
        let maxLat = max(start.latitude, end.latitude) + bufferKm / 111.0
        let minLon = min(start.longitude, end.longitude) - bufferKm / (111.0 * cos(((start.latitude + end.latitude) / 2) * .pi / 180))
        let maxLon = max(start.longitude, end.longitude) + bufferKm / (111.0 * cos(((start.latitude + end.latitude) / 2) * .pi / 180))

        return cameras.filter { camera in
            camera.latitude >= minLat && camera.latitude <= maxLat &&
            camera.longitude >= minLon && camera.longitude <= maxLon
        }
        .sorted { a, b in
            let distA = midpointDistance(a.coordinate, start, end)
            let distB = midpointDistance(b.coordinate, start, end)
            return distA < distB
        }
    }

    private func midpointDistance(_ point: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let mid = CLLocation(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        return mid.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
    }

    // MARK: - Response Parsing

    /// Parses the primary trip plus any alternates into candidate routes.
    private func parseCandidates(_ data: Data) throws -> [ValhallaRoute] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trip = json["trip"] as? [String: Any] else {
            throw RoutingError.invalidResponse
        }
        var routes = [parseTrip(trip)]
        if let alternates = json["alternates"] as? [[String: Any]] {
            for alt in alternates {
                if let altTrip = alt["trip"] as? [String: Any] {
                    routes.append(parseTrip(altTrip))
                }
            }
        }
        return routes
    }

    /// Picks the candidate with the fewest cameras near its path; ties go to
    /// the fastest travel time. Never trades extra camera passes for saved
    /// time or distance.
    private func bestCandidate(
        _ candidates: [ValhallaRoute],
        scoredAgainst cameras: [SurveillanceCamera],
        level: AvoidanceLevel,
        useFOV: Bool = false
    ) -> ValhallaRoute {
        guard candidates.count > 1, !cameras.isEmpty else { return candidates[0] }
        let scored = candidates.map { route in
            (route: route, exposure: exposureCount(route: route, cameras: cameras, radiusMeters: Self.scoringRadiusMeters, useFOV: useFOV))
        }
        return scored.min { a, b in
            if a.exposure != b.exposure { return a.exposure < b.exposure }
            return a.route.timeSeconds < b.route.timeSeconds
        }!.route
    }

    /// Counts cameras within `radiusMeters` of the route polyline
    /// (point-to-segment distance, planar approximation).
    /// When `useFOV` is true, a camera only counts as exposed if the nearest
    /// on-route point inside its radius also falls inside its field-of-view
    /// cone. This keeps the engine's scoring consistent with wedge-based
    /// avoidance and with RouteView's FOV-aware card count; otherwise the
    /// engine optimizes a different objective than the one the UI grades it on.
    private func exposureCount(route: ValhallaRoute, cameras: [SurveillanceCamera], radiusMeters: Double, useFOV: Bool = false) -> Int {
        exposedCameraIDs(route: route, cameras: cameras, radiusMeters: radiusMeters, useFOV: useFOV).count
    }

    /// The IDs of the cameras within `radiusMeters` of the route polyline;
    /// `exposureCount` is this set's size. Same geometry and FOV rules.
    private func exposedCameraIDs(route: ValhallaRoute, cameras: [SurveillanceCamera], radiusMeters: Double, useFOV: Bool = false) -> Set<Int64> {
        let shape = route.coordinates
        guard shape.count >= 2 else { return [] }
        let midLat = shape[shape.count / 2].latitude
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(midLat * .pi / 180)
        var exposed = Set<Int64>()
        for camera in cameras {
            let px = camera.longitude * mPerDegLon
            let py = camera.latitude * mPerDegLat
            var hit = false
            for i in 0..<(shape.count - 1) {
                let ax = shape[i].longitude * mPerDegLon
                let ay = shape[i].latitude * mPerDegLat
                let bx = shape[i + 1].longitude * mPerDegLon
                let by = shape[i + 1].latitude * mPerDegLat
                let dx = bx - ax, dy = by - ay
                let lenSq = dx * dx + dy * dy
                let t = lenSq > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq)) : 0
                let cx = ax + t * dx, cy = ay + t * dy
                let distSq = (px - cx) * (px - cx) + (py - cy) * (py - cy)
                if distSq <= radiusMeters * radiusMeters {
                    if useFOV {
                        let nearest = CLLocationCoordinate2D(latitude: cy / mPerDegLat, longitude: cx / mPerDegLon)
                        if camera.isInFieldOfView(from: nearest) { hit = true; break }
                    } else {
                        hit = true
                        break
                    }
                }
            }
            if hit { exposed.insert(camera.id) }
        }
        return exposed
    }

    private func parseTrip(_ trip: [String: Any]) -> ValhallaRoute {
        let summary = trip["summary"] as? [String: Any]
        let totalLength = summary?["length"] as? Double ?? 0
        let totalTime = summary?["time"] as? Double ?? 0

        var allCoordinates: [CLLocationCoordinate2D] = []
        var maneuvers: [ValhallaManeuver] = []

        if let legs = trip["legs"] as? [[String: Any]] {
            for leg in legs {
                if let legShape = leg["shape"] as? String {
                    allCoordinates.append(contentsOf: decodePolyline6(legShape))
                }
                if let legManeuvers = leg["maneuvers"] as? [[String: Any]] {
                    for m in legManeuvers {
                        maneuvers.append(ValhallaManeuver(
                            type: m["type"] as? Int ?? 0,
                            instruction: m["instruction"] as? String ?? "",
                            streetNames: m["street_names"] as? [String] ?? [],
                            length: m["length"] as? Double ?? 0,
                            time: m["time"] as? Double ?? 0,
                            beginShapeIndex: m["begin_shape_index"] as? Int ?? 0,
                            endShapeIndex: m["end_shape_index"] as? Int ?? 0
                        ))
                    }
                }
            }
        }

        return ValhallaRoute(
            coordinates: allCoordinates,
            distanceKm: totalLength,
            timeSeconds: totalTime,
            maneuvers: maneuvers
        )
    }

    // Valhalla uses 6-digit precision polyline encoding (not Google's 5-digit)
    private func decodePolyline6(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat: Int = 0
        var lon: Int = 0

        while index < encoded.endIndex {
            var shift = 0
            var result = 0
            var byte: Int

            repeat {
                byte = Int(encoded[index].asciiValue! - 63)
                index = encoded.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20

            lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

            shift = 0
            result = 0

            repeat {
                byte = Int(encoded[index].asciiValue! - 63)
                index = encoded.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20

            lon += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

            coordinates.append(CLLocationCoordinate2D(
                latitude: Double(lat) / 1e6,
                longitude: Double(lon) / 1e6
            ))
        }

        return coordinates
    }
}

// MARK: - Response Models

struct ValhallaRoute {
    let coordinates: [CLLocationCoordinate2D]
    let distanceKm: Double
    let timeSeconds: Double
    let maneuvers: [ValhallaManeuver]
}

struct ValhallaManeuver {
    let type: Int
    let instruction: String
    let streetNames: [String]
    let length: Double
    let time: Double
    let beginShapeIndex: Int
    let endShapeIndex: Int
}

enum RoutingError: LocalizedError {
    case invalidResponse
    case noRouteFound
    case badRequest(String)
    case rateLimited
    case serverError(Int)
    case engineUnavailable
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Valhalla"
        case .noRouteFound: return "No camera-avoiding route could be found. Try a shorter distance or fewer cameras."
        case .badRequest(let msg): return "Routing error: \(msg)"
        case .rateLimited: return "Routing service is busy. Try again in a moment."
        case .serverError(let code): return "Routing server error (HTTP \(code))"
        case .engineUnavailable: return "No offline map region is downloaded for this area. Download one in Settings \u{2192} Offline Routing."
        case .offline: return "Routing needs a downloaded offline region or an internet connection."
        }
    }
}
