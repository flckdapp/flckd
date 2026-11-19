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

    static let voiceGuidanceKey = VoiceSettings.directionsKey

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
        /// Asked for, spoken and named prompts, when the trip used Kokoro.
        var kokoro: KokoroStats? = nil
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
    @ObservationIgnored private var promptSchedule = GuidancePromptSchedule()
    @ObservationIgnored private var routeSignals = RouteSignals()
    @ObservationIgnored private var signalTask: Task<Void, Never>?
    @ObservationIgnored private var signalGeneration = UUID()
    @ObservationIgnored private var voiceCosting = "auto"
    @ObservationIgnored private var announcedArrival = false
    @ObservationIgnored private var namesPlannedStep: Int?

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

    /// Per-trip only. Persistent master and per-prompt preferences are separate.
    private(set) var isMuted = false

    #if DEBUG
    /// Replays the route through `SimulatedLocationProvider` instead of taking
    /// real fixes, so step advance and deviation can be exercised on
    /// camera-avoiding geometry without driving. Debug builds only.
    var simulateDrive = false
    @ObservationIgnored private var simulatedProvider: DebugDriveLocationProvider?
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
        VoiceSettings.migrate()
        proximityEngine.voiceContext = { [weak self] in
            self?.voiceContext ?? VoicePlaybackContext()
        }
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
        VoicePromptPlayer.shared.updateContext(voiceContext)
        startError = nil
        tripSummary = nil
        lastReroute = nil
        rerouteFailed = false
        rerouteCount = 0
        self.routeCameras = routeCameras

        let options = RoutePlanOptions.fromDefaults()
        voiceCosting = options.costing
        announcedArrival = false
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
                let simulated = try DebugDriveLocationProvider(route: route, settings: .fromDefaults(), locationManager: locationManager)
                simulatedProvider = simulated
                locationProvider = simulated
            } else {
                locationProvider = locationAdapter
            }
            #else
            locationProvider = locationAdapter
            #endif

            let core = FerrostarCore(
                customRouteProvider: provider,
                locationProvider: locationProvider,
                navigationControllerConfig: Self.navigationConfig,
                networkSession: NoNetworkRequestLoader(),
                spokenInstructionObserver: SpokenInstructionObserver(
                    synthesizer: SilentNavigationSynthesizer(), isMuted: true, managesAudioSession: false
                ),
                widgetProvider: FlckdNavigationWidgetProvider(liveActivityManager: liveActivityManager)
            )
            core.delegate = self
            self.core = core
            isMuted = false
            mirrorState(of: core)

            try core.startNavigation(route: route)

            LocalValhallaEngine.shared.keepAliveInBackground = true
            plannedDistanceMeters = route.distance
            startedAt = Date()
            statsAtStart = proximityEngine.tripStats
            self.destination = destination
            currentRoute = route
            proximityEngine.setSpeechRoute(route.geometry.map(\.clLocationCoordinate2D),
                                           cameras: cameraStore.cameras)
            isActive = true
            isStarting = false
            VoicePromptPlayer.shared.updateContext(voiceContext)
            VoicePromptPlayer.shared.resetKokoroStats()
            KokoroNameRenderer.shared.beginTrip()
            planNames(route: route, from: 0)
            speak(["depart"])
            loadSignals(for: route)
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

    private func teardown(preserveArrivalPrompt: Bool = false) {
        signalTask?.cancel()
        signalTask = nil
        signalGeneration = UUID()
        routeSignals = RouteSignals()
        promptSchedule.reset()
        KokoroNameRenderer.shared.endTrip()
        namesPlannedStep = nil
        if !preserveArrivalPrompt { VoicePromptPlayer.shared.cancel(.guidance) }
        core?.stopNavigation()
        proximityEngine.setSpeechRoute(nil)
        #if DEBUG
        simulatedProvider?.stopUpdating()
        simulatedProvider = nil
        #endif
        cancellables.removeAll()
        core = nil
        // `stopNavigation()` calls the adapter for us, but a failed start may
        // never have reached it, and leaving the manager in navigation mode
        // would drain the battery of a user who is not navigating.
        locationAdapter.stopUpdating()
        LocalValhallaEngine.shared.keepAliveInBackground = false
        isActive = false
        isMuted = false
        isStarting = false
        VoicePromptPlayer.shared.updateContext(voiceContext)
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
        guard isActive else { return }
        isMuted.toggle()
        VoicePromptPlayer.shared.updateContext(voiceContext)
    }

    func setVoiceGuidance(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.voiceGuidanceKey)
        VoicePromptPlayer.shared.settingsDidChange()
    }

    private var voiceContext: VoicePlaybackContext {
        VoicePlaybackContext(navigating: isActive || isStarting, tripMuted: isMuted)
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
        if let progress = newState?.currentProgress, let route = currentRoute,
           let steps = newState?.remainingSteps {
            let completed = max(0, route.steps.count - steps.count)
            let toManeuver = route.steps.prefix(completed + 1).reduce(0.0) {
                $0 + (RouteSignals.cumulative($1.geometry).last ?? 0)
            }
            proximityEngine.updateSpeechProgress(traveled: toManeuver - progress.distanceToNextManeuver,
                                                 onRoute: newState?.currentDeviation == .noDeviation)
            if completed != namesPlannedStep { planNames(route: route, from: completed) }
        }
        if let newState { speakInstruction(from: newState) }
        guard let newState, case .complete = newState.tripState else { return }
        finish()
    }

    private func speak(_ clips: [String], fallback: String = "", kind: VoicePromptKind = .directions,
                       roadName: String? = nil) {
        guard VoiceSettings.fromDefaults().allows(kind, context: voiceContext) else { return }
        VoicePromptPlayer.shared.enqueue(VoiceUtterance(
            clips: clips, fallbackText: fallback, voice: .selected,
            kind: kind,
            createdAt: ProcessInfo.processInfo.systemUptime,
            kokoro: KokoroSelection.requested(),
            roadName: roadName
        ))
    }

    /// Hands the name renderer the next steps, so street names for their
    /// approach prompts can be rendered ahead. Nothing happens unless the
    /// Kokoro voice, its engine and "Say street names" are all on.
    private func planNames(route: Route, from completed: Int) {
        namesPlannedStep = completed
        guard KokoroSupport.namesEnabled(), let preset = KokoroSelection.requested() else { return }
        let steps = KokoroNamePlanner.steps(Array(route.steps.dropFirst(completed)))
        KokoroNameRenderer.shared.plan(steps: steps, units: .selected(), preset: preset)
    }

    private func speakInstruction(from state: NavigationState) {
        guard case let .navigating(_, user, _, steps, _, progress, _, deviation, visual, spoken, _) = state.tripState,
              case .noDeviation = deviation, let step = steps.first, let route = currentRoute else { return }
        let completed = max(0, route.steps.count - steps.count)
        // The current banner can appear later than the first progress update;
        // the step's stored banner still describes the same upcoming maneuver.
        let banner = visual ?? step.visualInstructions.first
        let speed = user.speed?.value ?? (step.duration > 0 ? step.distance / step.duration : 13.4)
        let units = DistanceUnits.selected()
        guard let prompt = promptSchedule.update(
            step: completed, length: step.distance, remaining: progress.distanceToNextManeuver, speed: speed, units: units
        ) else { return }
        if case let .continueRoad(key) = prompt {
            speak([key])
            return
        }
        let approach: Bool
        let distance: Double
        switch prompt {
        case .approach(_, let meters): approach = true; distance = meters
        case .final: approach = false; distance = 0
        case .continueRoad: return
        }
        let next = steps.dropFirst().first
        let settings = VoiceSettings.fromDefaults()
        var signal: String?
        if let point = step.geometry.last {
            let targetDistance = route.steps.prefix(completed + 1).reduce(0.0) {
                $0 + (RouteSignals.cumulative($1.geometry).last ?? 0)
            }
            signal = routeSignals.prefix(
                maneuver: point, targetDistance: targetDistance,
                userDistance: targetDistance - progress.distanceToNextManeuver, approach: approach
            )
        }
        let clips = GuidancePromptSelector.select(
            content: banner?.primaryContent, distance: distance,
            roundaboutExit: next?.roundaboutExitNumber,
            laneInfo: banner?.subContent?.laneInfo, signal: signal,
            lanesEnabled: settings.allows(.lane, context: voiceContext),
            trafficLightsEnabled: settings.allows(.trafficLight, context: voiceContext), isApproach: approach, units: units
        )
        if clips.first?.hasPrefix("arrive") == true { announcedArrival = true }
        let roadName = approach && KokoroSupport.namesEnabled() ? banner?.primaryContent.text : nil
        speak(clips, fallback: spoken?.text ?? banner?.primaryContent.text ?? next?.instruction ?? step.instruction,
              roadName: roadName)
    }

    private func loadSignals(for route: Route) {
        signalTask?.cancel()
        routeSignals = RouteSignals()
        let generation = UUID()
        signalGeneration = generation
        let geometry = route.geometry
        let costing = voiceCosting
        signalTask = Task { [weak self] in
            let signals = await RouteSignals.load(geometry: geometry, costing: costing)
            guard !Task.isCancelled, let self, self.isActive, self.signalGeneration == generation else { return }
            self.routeSignals = signals
        }
    }

    func playVoiceSample(_ voice: PromptVoice) {
        guard !isActive, !isStarting,
              VoiceSettings.fromDefaults().allows(.preview, context: voiceContext) else { return }
        VoicePromptPlayer.shared.enqueue(.preview(voice: voice, now: ProcessInfo.processInfo.systemUptime, units: .selected()))
    }

    func playKokoroSample(_ preset: KokoroPreset) {
        guard !isActive, !isStarting,
              VoiceSettings.fromDefaults().allows(.preview, context: voiceContext) else { return }
        VoicePromptPlayer.shared.enqueue(.kokoroPreview(preset: preset, now: ProcessInfo.processInfo.systemUptime, units: .selected()))
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
            rerouteCount: rerouteCount,
            kokoro: { let counts = VoicePromptPlayer.shared.kokoroStats(); return counts.requested > 0 ? counts : nil }()
        )
        Self.log.info("guidance complete after \(self.rerouteCount) reroutes")
        if !announcedArrival { speak(["arrive"]) }
        teardown(preserveArrivalPrompt: true)
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
        if rerouting { speak(["rerouting"], kind: .rerouting) }
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
            VoicePromptPlayer.shared.cancel(.guidance)
            #if DEBUG
            try simulatedProvider?.replaceRoute(route)
            #endif
            try core.startNavigation(route: route)
            plannedDistanceMeters = max(0, plannedDistanceMeters - remaining) + route.distance
            currentRoute = route
            proximityEngine.setSpeechRoute(route.geometry.map(\.clLocationCoordinate2D),
                                           cameras: cameraStore.cameras)
            promptSchedule.reset()
            planNames(route: route, from: 0)
            rerouteCount += 1
            speak(["new_route"], kind: .rerouting)
            loadSignals(for: route)
        } catch {
            Self.log.error("reroute could not start: \(error.localizedDescription, privacy: .public)")
            rerouteFailed = true
        }
    }
}
