import CoreLocation
import Foundation
import os
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// The planner settings a guidance session reads once at start, from the same
/// `UserDefaults` keys the route planner's own controls write.
struct RoutePlanOptions: Sendable {
    var avoidanceLevel: AvoidanceLevel
    var useFOV: Bool
    var costing: String
    var useMetric: Bool

    static let avoidanceLevelKey = "avoidanceLevel"
    static let useMetricKey = "useMetric"

    /// `useFOV` is false and `costing` is "auto" to match `RouteView`: wedge
    /// avoidance lets a route pass directly behind a camera pole, so planning
    /// always keeps physical distance from the whole camera.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> RoutePlanOptions {
        RoutePlanOptions(
            avoidanceLevel: AvoidanceLevel(rawValue: defaults.integer(forKey: avoidanceLevelKey)) ?? .balanced,
            useFOV: false,
            costing: "auto",
            useMetric: defaults.bool(forKey: useMetricKey)
        )
    }
}

struct RoutePlanStats: Sendable {
    let avoidedCount: Int
    let totalCount: Int
    let date: Date
}

/// Generates guidance routes from the on-device engine.
///
/// FerrostarCore calls this for the first route and again for every reroute,
/// which is what keeps camera avoidance alive for the whole trip: a reroute is
/// a fresh run of the progressive-avoidance planner from the current position,
/// not a plain shortest path.
final class FlckdRouteProvider: CustomRouteProvider, Sendable {

    private static let log = Logger(subsystem: "io.vws.app.flckd", category: "navigation")

    /// How far a candidate's length may differ from the previewed route's
    /// before it is assumed to be a different route. Valhalla is deterministic,
    /// so the OSRM re-issue should match exactly; the tolerance absorbs
    /// rounding between the native summary's kilometres and OSRM's metres.
    private static let distanceTolerance = 0.02

    private let routing: ValhallaRoutingService
    private let options: RoutePlanOptions
    private let cameras: @Sendable (BoundingBox) async -> [SurveillanceCamera]
    private let planned: @Sendable (Result<RoutePlanStats, Error>) -> Void

    init(
        routing: ValhallaRoutingService,
        options: RoutePlanOptions,
        cameras: @escaping @Sendable (BoundingBox) async -> [SurveillanceCamera],
        planned: @escaping @Sendable (Result<RoutePlanStats, Error>) -> Void
    ) {
        self.routing = routing
        self.options = options
        self.cameras = cameras
        self.planned = planned
    }

    /// Reports through `planned` on every exit, including the guard: that
    /// callback is how the session controller learns a reroute stopped being
    /// in flight, so a path that threw without reporting would latch it on.
    func getRoutes(userLocation: UserLocation, waypoints: [Waypoint]) async throws -> [Route] {
        do {
            guard let last = waypoints.last else { throw NavigationError.noWaypoints }
            let origin = userLocation.coordinates.clLocationCoordinate2D
            let destination = last.coordinate.clLocationCoordinate2D
            let corridor = Self.corridorBounds(from: origin, to: destination)
            let corridorCameras = await cameras(corridor)

            let plan = try await routing.routeWithProgressiveAvoidance(
                from: origin,
                to: destination,
                cameras: corridorCameras,
                useFOV: options.useFOV,
                costing: options.costing,
                level: options.avoidanceLevel,
                heading: userLocation.courseOverGround.map { Double($0.degrees) }
            )
            let response = try await routing.navigationResponse(for: plan, useMetric: options.useMetric)
            guard let chosen = Self.select(try Self.routes(fromOSRM: response), for: plan) else {
                throw NavigationError.noRouteInResponse
            }
            let stats = RoutePlanStats(
                avoidedCount: plan.avoidedCount,
                totalCount: plan.totalCount,
                date: Date()
            )
            Self.log.info("guidance route: avoided \(stats.avoidedCount) of \(stats.totalCount) corridor cameras")
            planned(.success(stats))
            return [chosen]
        } catch {
            Self.log.error("guidance route failed: \(error.localizedDescription, privacy: .public)")
            planned(.failure(error))
            throw error
        }
    }

    static func routes(fromOSRM data: Data) throws -> [Route] {
        // Valhalla's OSRM serializer emits polyline6 by default, and the
        // request asks for it explicitly.
        try createOsrmResponseParser(polylinePrecision: 6).parseResponse(response: data)
    }

    /// Finds the previewed route in the OSRM re-issue of its own request.
    ///
    /// The index alone would be enough if the engine were guaranteed to order
    /// candidates identically across response formats. Checking the length
    /// first makes a mismatch degrade to the primary route instead of silently
    /// navigating an alternate the user never saw.
    static func select(_ routes: [Route], for plan: RoutePlan) -> Route? {
        guard !routes.isEmpty else { return nil }
        let expected = plan.route.distanceKm * 1000
        if expected > 0, routes.indices.contains(plan.candidateIndex) {
            let candidate = routes[plan.candidateIndex]
            if abs(candidate.distance - expected) <= expected * distanceTolerance {
                return candidate
            }
        }
        return routes.first
    }

    static func corridorBounds(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> BoundingBox {
        let bufferKm = ValhallaRoutingService.corridorBufferKm
        let latBuffer = bufferKm / 111.0
        let lonBuffer = bufferKm / (111.0 * cos(((start.latitude + end.latitude) / 2) * .pi / 180))
        return BoundingBox(
            south: min(start.latitude, end.latitude) - latBuffer,
            west: min(start.longitude, end.longitude) - lonBuffer,
            north: max(start.latitude, end.latitude) + latBuffer,
            east: max(start.longitude, end.longitude) + lonBuffer
        )
    }
}
