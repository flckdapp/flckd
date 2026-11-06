import Combine
import CoreLocation
import Foundation
import Observation
import os
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// Owns a turn-by-turn guidance session.
///
/// `FerrostarCore` is a non-`Sendable`, non-isolated `NSObject` that publishes
/// on the main queue, so it is created and talked to only from here, and its
/// state is mirrored onto an observable property for the UI. One core per
/// session: a fresh instance per trip is cheaper to reason about than resetting
/// a long-lived one, and it means a reroute that lands after the user stopped
/// cannot revive a finished trip.
///
/// Lives at app scope beside `ProximityAlertEngine` rather than on a view.
/// Guidance has to survive a tab switch.
@Observable @MainActor
final class NavigationSessionController: NSObject, @preconcurrency FerrostarCoreDelegate {

    static let voiceGuidanceKey = "voiceGuidanceEnabled"

    private static let log = Logger(subsystem: "io.vws.app.flckd", category: "navigation")

    /// Within this distance of the destination, a deviation is treated as
    /// arrival rather than a wrong turn. Without it, overshooting the pin by a
    /// few metres triggers a reroute back to it, and the trip never completes.
    private static let arrivalRadiusMeters: CLLocationDistance = 100

    struct Destination: Sendable {
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    struct RerouteInfo: Sendable {
        let avoidedCount: Int
        let totalCount: Int
        let date: Date
    }

    /// Held in memory for the length of one summary card and never written
    /// anywhere: duration, distance and camera counts together describe a trip.
    struct TripSummary: Sendable {
        let duration: TimeInterval
        let distanceMeters: Double
        let camerasEncountered: Int
        let alprCount: Int
        let speedCount: Int
        let otherCount: Int
        let rerouteCount: Int
    }

    private let locationManager: LocationManager
    private let cameraStore: CameraStore
    private let proximityEngine: ProximityAlertEngine
    private let liveActivityManager: LiveActivityManager
    private let routingService: ValhallaRoutingService
    private let locationAdapter: NavigationLocationAdapter

    @ObservationIgnored private var core: FerrostarCore?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var statsAtStart: ProximityAlertEngine.TripStats?
    @ObservationIgnored private var plannedDistanceMeters: Double = 0
    @ObservationIgnored private var rerouteCount = 0
    @ObservationIgnored private var routeCameras: [SurveillanceCamera] = []

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isRerouting = false
    private(set) var state: NavigationState?
    private(set) var currentRoute: Route?
    private(set) var destination: Destination?
    private(set) var lastReroute: RerouteInfo?
    private(set) var rerouteFailed = false
    private(set) var startError: Error?
    private(set) var tripSummary: TripSummary?

    /// Read-only because the live `SpokenInstructionObserver` only exposes a
    /// toggle; a plain setter here could not keep the two in step.
    private(set) var isMuted = false

    #if DEBUG
    /// Replays the route through `SimulatedLocationProvider` instead of taking
    /// real fixes, so step advance and deviation can be exercised on
    /// camera-avoiding geometry without driving. Debug builds only.
    var simulateDrive = false
    #endif

    init(
        locationManager: LocationManager,
        cameraStore: CameraStore,
        proximityEngine: ProximityAlertEngine,
        liveActivityManager: LiveActivityManager,
        routingService: ValhallaRoutingService
    ) {
        self.locationManager = locationManager
        self.cameraStore = cameraStore
        self.proximityEngine = proximityEngine
        self.liveActivityManager = liveActivityManager
        self.routingService = routingService
        locationAdapter = NavigationLocationAdapter(locationManager: locationManager)
        super.init()
        UserDefaults.standard.register(defaults: [Self.voiceGuidanceKey: true])
        isMuted = !UserDefaults.standard.bool(forKey: Self.voiceGuidanceKey)
    }

    // MARK: - Session Lifecycle

    /// Starts guidance on the route the user previewed.
    ///
    /// The plan is re-issued in OSRM format rather than replanned: the user
    /// agreed to a specific route and a fresh plan could legitimately return a
    /// different one.
    func start(plan: RoutePlan, destination: Destination, routeCameras: [SurveillanceCamera]) async {
        guard !isActive, !isStarting else { return }
        isStarting = true
        startError = nil
        tripSummary = nil
        lastReroute = nil
        rerouteFailed = false
        rerouteCount = 0
        self.routeCameras = routeCameras

        let options = RoutePlanOptions.fromDefaults()
        do {
            let response = try await routingService.navigationResponse(for: plan, useMetric: options.useMetric)
            guard let route = FlckdRouteProvider.select(try FlckdRouteProvider.routes(fromOSRM: response), for: plan) else {
                throw NavigationError.noRouteInResponse
            }

            let provider = FlckdRouteProvider(
                routing: routingService,
                options: options,
                cameras: { [weak self] bounds in
                    await self?.cameras(in: bounds) ?? []
                },
                planned: { [weak self] result in
                    Task { @MainActor in self?.recordPlan(result) }
                }
            )

            let locationProvider: LocationProviding
            #if DEBUG
            if simulateDrive {
                let simulated = SimulatedLocationProvider()
                simulated.warpFactor = 4
                try simulated.setSimulatedRoute(route)
                locationProvider = simulated
            } else {
                locationProvider = locationAdapter
            }
            #else
            locationProvider = locationAdapter
            #endif

            let voiceEnabled = UserDefaults.standard.bool(forKey: Self.voiceGuidanceKey)
            // `managesAudioSession` stays at Ferrostar's default: it already
            // ducks other audio per utterance and releases afterwards, which
            // is what a navigation app wants, and two owners of one session
            // fight each other.
            let core = FerrostarCore(
                customRouteProvider: provider,
                locationProvider: locationProvider,
                navigationControllerConfig: Self.navigationConfig,
                networkSession: NoNetworkRequestLoader(),
                spokenInstructionObserver: .initAVSpeechSynthesizer(isMuted: !voiceEnabled),
                widgetProvider: FlckdNavigationWidgetProvider(liveActivityManager: liveActivityManager)
            )
            core.delegate = self
            self.core = core
            isMuted = !voiceEnabled
            mirrorState(of: core)

            try core.startNavigation(route: route)

            LocalValhallaEngine.shared.keepAliveInBackground = true
            plannedDistanceMeters = route.distance
            startedAt = Date()
            statsAtStart = proximityEngine.tripStats
            self.destination = destination
            currentRoute = route
            isActive = true
            isStarting = false
            Self.log.info("guidance started: \(Int(route.distance))m, \(route.steps.count) steps")
        } catch {
            Self.log.error("guidance start failed: \(error.localizedDescription, privacy: .public)")
            startError = error
            teardown()
        }
    }

    /// Ends the session. Also the arrival path, once the summary is built.
    func stop() {
        guard isActive || isStarting || core != nil else { return }
        teardown()
    }

    func dismissSummary() {
        tripSummary = nil
    }

    private func teardown() {
        core?.stopNavigation()
        cancellables.removeAll()
        core = nil
        // `stopNavigation()` calls the adapter for us, but a failed start may
        // never have reached it, and leaving the manager in navigation mode
        // would drain the battery of a user who is not navigating.
        locationAdapter.stopUpdating()
        LocalValhallaEngine.shared.keepAliveInBackground = false
        isActive = false
        isStarting = false
        isRerouting = false
        rerouteFailed = false
        state = nil
        currentRoute = nil
        destination = nil
        startedAt = nil
        statsAtStart = nil
        plannedDistanceMeters = 0
        routeCameras = []
    }

    // MARK: - Voice

    func toggleMute() {
        setVoiceGuidance(enabled: isMuted)
    }

    func setVoiceGuidance(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.voiceGuidanceKey)
        guard isMuted == enabled else { return }
        core?.spokenInstructionObserver.toggleMute()
        isMuted = !enabled
    }

    // MARK: - State Mirroring

    /// Internal rather than private so the behaviour tests drive the real core
    /// with exactly this configuration.
    nonisolated static var navigationConfig: SwiftNavigationControllerConfig {
        SwiftNavigationControllerConfig(
            waypointAdvance: .waypointWithinRange(100),
            stepAdvanceCondition: stepAdvanceDistanceEntryAndExit(
                distanceToEndOfStep: 30,
                distanceAfterEndOfStep: 5,
                minimumHorizontalAccuracy: 32
            ),
            arrivalStepAdvanceCondition: stepAdvanceDistanceToEndOfStep(
                distance: 30,
                minimumHorizontalAccuracy: 32
            ),
            routeDeviationTracking: .staticThreshold(
                minimumHorizontalAccuracy: 25,
                maxAcceptableDeviation: 50
            ),
            snappedLocationCourseFiltering: .snapToRoute
        )
    }

    private func mirrorState(of core: FerrostarCore) {
        core.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                // Safe because of `receive(on:)` above, and necessary because
                // `Published` predates actor isolation.
                MainActor.assumeIsolated { self?.apply(state) }
            }
            .store(in: &cancellables)
    }

    private func apply(_ newState: NavigationState?) {
        state = newState
        guard let newState, case .complete = newState.tripState else { return }
        finish()
    }

    /// Builds the summary, then stops immediately: a reroute that completes
    /// after arrival would otherwise restart guidance on a finished trip
    /// (Ferrostar issue #951).
    private func finish() {
        guard isActive else { return }
        let now = Date()
        let stats = proximityEngine.tripStats
        let before = statsAtStart ?? ProximityAlertEngine.TripStats()
        let remaining = state?.currentProgress?.distanceRemaining ?? 0

        tripSummary = TripSummary(
            duration: now.timeIntervalSince(startedAt ?? now),
            distanceMeters: max(0, plannedDistanceMeters - remaining),
            camerasEncountered: max(0, stats.totalCount - before.totalCount),
            alprCount: max(0, stats.alprCount - before.alprCount),
            speedCount: max(0, stats.speedCount - before.speedCount),
            otherCount: max(0, stats.otherCount - before.otherCount),
            rerouteCount: rerouteCount
        )
        Self.log.info("guidance complete after \(self.rerouteCount) reroutes")
        teardown()
    }

    // MARK: - Camera Data

    /// The camera set a reroute plans against.
    ///
    /// Only ever asks `CameraStore`, which fetches by fixed DeFlock tile or
    /// whole-degree grid cell. No request is derived from the user's position.
    /// On failure it falls back to what is already in memory, so a reroute in a
    /// dead spot still avoids the cameras the app knows about.
    private func cameras(in bounds: BoundingBox) async -> [SurveillanceCamera] {
        var byID: [Int64: SurveillanceCamera] = [:]
        do {
            for camera in try await cameraStore.fetchFromBestSource(in: bounds) {
                byID[camera.id] = camera
            }
        } catch {
            for camera in cameraStore.cameras where bounds.contains(camera.coordinate) {
                byID[camera.id] = camera
            }
        }
        // Keep the cameras the previewed route was planned against fenced for
        // the rest of the trip, whatever this fetch returned.
        for camera in routeCameras where bounds.contains(camera.coordinate) {
            byID[camera.id] = camera
        }
        return Array(byID.values)
    }

    private func recordPlan(_ result: Result<RoutePlanStats, Error>) {
        switch result {
        case let .success(stats):
            lastReroute = RerouteInfo(
                avoidedCount: stats.avoidedCount,
                totalCount: stats.totalCount,
                date: stats.date
            )
            rerouteFailed = false
        case .failure:
            // Guidance carries on along the old route. Ferrostar asks again
            // after its 5 s / 50 m throttle.
            setRerouting(false)
            rerouteFailed = true
        }
    }

    /// The lock screen is told as well: Ferrostar hands the widget provider no
    /// instruction while the driver is completely off the route, so the
    /// provider alone could never show the spinner.
    private func setRerouting(_ rerouting: Bool) {
        guard isRerouting != rerouting else { return }
        isRerouting = rerouting
        let liveActivityManager = liveActivityManager
        Task { await liveActivityManager.setNavigationRerouting(rerouting) }
    }

    // MARK: - FerrostarCoreDelegate

    func core(_: FerrostarCore, didStartWith route: Route) {
        currentRoute = route
    }

    func core(
        _: FerrostarCore,
        correctiveActionForDeviation _: DeviationKind,
        remainingWaypoints waypoints: [Waypoint]
    ) -> CorrectiveAction {
        if let here = state?.preferredUserLocation, let destination {
            let distance = here.clLocation.distance(
                from: CLLocation(
                    latitude: destination.coordinate.latitude,
                    longitude: destination.coordinate.longitude
                )
            )
            if distance <= Self.arrivalRadiusMeters { return .doNothing }
        }
        setRerouting(true)
        rerouteFailed = false
        return .getNewRoutes(waypoints: waypoints)
    }

    /// Unlike every other callback, Ferrostar makes this one from its reroute
    /// task, off the main queue. The `@preconcurrency` witness would trap on
    /// arrival, so it is non-isolated and hops by hand.
    nonisolated func core(_ core: FerrostarCore, loadedAlternateRoutes routes: [Route]) {
        let coreID = ObjectIdentifier(core)
        Task { @MainActor [weak self] in
            self?.acceptReroute(routes, from: coreID)
        }
    }

    private func acceptReroute(_ routes: [Route], from coreID: ObjectIdentifier) {
        defer { setRerouting(false) }
        guard isActive, let core, ObjectIdentifier(core) == coreID, let route = routes.first else { return }
        do {
            // The summary's distance is planned length less what remains, so
            // switching routes has to bank the part already driven first.
            let remaining = state?.currentProgress?.distanceRemaining ?? plannedDistanceMeters
            try core.startNavigation(route: route)
            plannedDistanceMeters = max(0, plannedDistanceMeters - remaining) + route.distance
            currentRoute = route
            rerouteCount += 1
        } catch {
            Self.log.error("reroute could not start: \(error.localizedDescription, privacy: .public)")
            rerouteFailed = true
        }
    }
}
