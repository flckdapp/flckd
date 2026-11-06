import AVFoundation
import Combine
import CoreLocation
import os
import XCTest
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

/// Drives the real Rust core through `FerrostarCore` on the route shape camera
/// avoidance produces: out along one road, a tight hairpin, and back within
/// 40 m of the outbound leg. No GPS, no tiles and no network: fixes are pushed
/// by hand and every route is a synthetic OSRM response built from offsets of
/// the null island in 0.0001–0.001 degree steps.
///
/// The configuration is the one `NavigationSessionController` ships, so a
/// change to the step-advance or deviation thresholds is tested here first.
@MainActor
final class NavigationRerouteBehaviourTests: XCTestCase {

    // MARK: - Geometry

    /// A north to B, B east to C across the hairpin, C south to D parallel to
    /// the first leg and 40 m from it, D east to E.
    private static let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    private static let b = CLLocationCoordinate2D(latitude: 0.001, longitude: 0)
    private static let c = CLLocationCoordinate2D(latitude: 0.001, longitude: 0.00036)
    private static let d = CLLocationCoordinate2D(latitude: 0, longitude: 0.00036)
    private static let e = CLLocationCoordinate2D(latitude: 0, longitude: 0.001)

    /// 80 m west of the northbound leg and more than 50 m from every step.
    private static let offRoute = CLLocationCoordinate2D(latitude: 0.0005, longitude: -0.00072)

    private static let hairpinSteps: [OSRMFixture.Step] = [
        step([a, b], "depart", nil, "Head north on First Street", "First Street"),
        step([b, c], "turn", "right", "Turn right onto Connector Lane", "Connector Lane"),
        step([c, d], "turn", "right", "Turn right onto Second Street", "Second Street"),
        step([d, e], "turn", "left", "Turn left onto Third Street", "Third Street"),
        step([e, e], "arrive", nil, "You have arrived", "Third Street"),
    ]

    private static let detourSteps: [OSRMFixture.Step] = [
        step([offRoute, e], "depart", nil, "Head east on Detour Road", "Detour Road"),
        step([e, e], "arrive", nil, "You have arrived", "Detour Road"),
    ]

    /// Fixes roughly every 10 m along the whole route, start excluded.
    private static let drive: [CLLocationCoordinate2D] =
        between(a, b, steps: 10) + between(b, c, steps: 3) + between(c, d, steps: 10) + between(d, e, steps: 8)

    // MARK: - Fixtures

    private var locationProvider: FakeLocationProvider!
    private var routeProvider: FakeRouteProvider!
    private var delegate: RecordingDelegate!
    private var loader: RequestLoaderSpy!
    private var core: FerrostarCore!
    private var hairpin: Route!
    private var detour: Route!
    private var cancellables = Set<AnyCancellable>()
    private var tick: TimeInterval = 0

    override func setUp() async throws {
        try await super.setUp()
        hairpin = try XCTUnwrap(FlckdRouteProvider.routes(fromOSRM: OSRMFixture.response(steps: Self.hairpinSteps)).first)
        detour = try XCTUnwrap(FlckdRouteProvider.routes(fromOSRM: OSRMFixture.response(steps: Self.detourSteps)).first)
        locationProvider = FakeLocationProvider()
        routeProvider = FakeRouteProvider(routes: [detour])
        delegate = RecordingDelegate()
        loader = RequestLoaderSpy()
        core = FerrostarCore(
            customRouteProvider: routeProvider,
            locationProvider: locationProvider,
            navigationControllerConfig: NavigationSessionController.navigationConfig,
            networkSession: loader,
            spokenInstructionObserver: SpokenInstructionObserver(
                synthesizer: NoOpSpeechSynthesizer(),
                isMuted: true,
                managesAudioSession: false
            )
        )
        core.delegate = delegate
    }

    override func tearDown() async throws {
        XCTAssertEqual(loader.requests, 0, "guidance must never reach the network session")
        cancellables.removeAll()
        core.stopNavigation()
        core = nil
        try await super.tearDown()
    }

    // MARK: - Step advance

    func testStepsAdvanceOneAtATimeThroughTheHairpin() async throws {
        try start()
        XCTAssertEqual(core.state?.remainingSteps?.count, 5)

        var trace: [(fix: CLLocationCoordinate2D, remaining: Int?)] = []
        for point in Self.drive {
            let state = await drive(to: fix(at: point))
            trace.append((point, state?.remainingSteps?.count))
            if state?.isComplete == true { break }
            XCTAssertNotNil(state?.currentVisualInstruction, "no banner at \(point)")
            XCTAssertEqual(state?.currentDeviation, .noDeviation, "flagged off route at \(point)")
        }

        let counts = trace.compactMap(\.remaining)
        XCTAssertEqual(counts.first, 5)
        for (earlier, later) in zip(counts, counts.dropFirst()) {
            XCTAssertTrue(later == earlier || later == earlier - 1, "remaining steps went \(earlier) -> \(later)")
        }

        XCTAssertTrue(trace.last?.remaining == nil, "the trip never completed")
        XCTAssertLessThanOrEqual(
            OSRMFixture.distance(from: try XCTUnwrap(trace.last?.fix), to: Self.e),
            30,
            "arrival fired outside the 30 m arrival radius"
        )

        // Each advance has to happen on the leg that follows the maneuver, not
        // while the car is still on the outbound leg 40 m from the inbound one.
        let ontoConnector = try XCTUnwrap(trace.first { $0.remaining == 4 }?.fix)
        XCTAssertEqual(ontoConnector.latitude, Self.b.latitude, accuracy: 1e-9)
        XCTAssertGreaterThan(ontoConnector.longitude, Self.b.longitude)

        let ontoSecondStreet = try XCTUnwrap(trace.first { $0.remaining == 3 }?.fix)
        XCTAssertEqual(ontoSecondStreet.longitude, Self.c.longitude, accuracy: 1e-9)
        XCTAssertLessThan(ontoSecondStreet.latitude, Self.c.latitude)

        let ontoThirdStreet = try XCTUnwrap(trace.first { $0.remaining == 2 }?.fix)
        XCTAssertEqual(ontoThirdStreet.latitude, Self.d.latitude, accuracy: 1e-9)
        XCTAssertGreaterThan(ontoThirdStreet.longitude, Self.d.longitude)

        XCTAssertTrue(delegate.deviations.isEmpty)
        XCTAssertTrue(routeProvider.calls.isEmpty)
    }

    // MARK: - Reroute

    func testThreeAccurateFixesOffRouteRerouteExactlyOnce() async throws {
        try start()
        for point in Self.between(Self.a, Self.b, steps: 10).prefix(4) {
            await drive(to: fix(at: point))
        }

        let alternatesLoaded = expectation(description: "loadedAlternateRoutes")
        delegate.onAlternates = { alternatesLoaded.fulfill() }
        let calculating = expectCalculatingFlagToRiseAndFall()

        let offRoute = [fix(at: Self.offRoute), fix(at: Self.offRoute), fix(at: Self.offRoute)]
        var flagged: [NavigationState?] = []
        for location in offRoute {
            flagged.append(await drive(to: location))
        }
        await fulfillment(of: [alternatesLoaded] + calculating, timeout: 5)

        // The detector reads the previous fix's position, so the first fix off
        // route only moves the car; the second carries the deviation and the
        // third shows the 5 s / 50 m throttle holding.
        XCTAssertEqual(flagged[0]?.currentDeviation, .noDeviation)
        guard case let .deviation(.completelyOffRoute(metres))? = flagged[1]?.currentDeviation else {
            return XCTFail("second fix off route was not flagged: \(String(describing: flagged[1]?.currentDeviation))")
        }
        XCTAssertEqual(metres, 80, accuracy: 1)
        XCTAssertNil(flagged[1]?.currentVisualInstruction, "a prompt was shown while completely off route")
        XCTAssertNil(flagged[2]?.currentVisualInstruction)

        XCTAssertEqual(delegate.deviations.count, 1)
        XCTAssertEqual(routeProvider.calls.count, 1)
        let call = try XCTUnwrap(routeProvider.calls.first)
        XCTAssertEqual(call.waypoints.map(\.coordinate), [GeographicCoordinate(Self.e)])
        XCTAssertEqual(call.userLocation.coordinates, GeographicCoordinate(Self.offRoute))
        XCTAssertEqual(call.userLocation.timestamp, offRoute[1].timestamp)
        XCTAssertEqual(call.userLocation.horizontalAccuracy, 5)
        XCTAssertEqual(delegate.alternates, [[detour]])

        // The app accepts the first alternate; the core must pick it up and
        // speak again now that the car is on a route.
        try core.startNavigation(route: detour)
        let onDetour = await drive(to: fix(at: Self.offRoute))
        XCTAssertEqual(core.route, detour)
        XCTAssertEqual(onDetour?.remainingSteps?.count, 2)
        XCTAssertNotNil(onDetour?.currentVisualInstruction)
        XCTAssertEqual(routeProvider.calls.count, 1)
    }

    func testAnInaccurateFixOffRouteDoesNotReroute() async throws {
        try start()
        for point in Self.between(Self.a, Self.b, steps: 10).prefix(4) {
            await drive(to: fix(at: point))
        }

        let coarse = [fix(at: Self.offRoute, accuracy: 150), fix(at: Self.offRoute, accuracy: 150)]
        var states: [NavigationState?] = []
        for location in coarse {
            states.append(await drive(to: location))
        }

        for state in states {
            XCTAssertEqual(state?.currentDeviation, .noDeviation)
            XCTAssertFalse(state?.isCalculatingNewRoute ?? true)
            XCTAssertEqual(state?.remainingSteps?.count, 5)
        }
        XCTAssertTrue(delegate.deviations.isEmpty)
        XCTAssertTrue(routeProvider.calls.isEmpty)

        // The same point with a usable fix is off route, which proves the
        // accuracy gate was what held the reroute back.
        let alternatesLoaded = expectation(description: "loadedAlternateRoutes")
        delegate.onAlternates = { alternatesLoaded.fulfill() }
        await drive(to: fix(at: Self.offRoute))
        await drive(to: fix(at: Self.offRoute))
        await fulfillment(of: [alternatesLoaded], timeout: 5)

        XCTAssertEqual(delegate.deviations.count, 1)
        XCTAssertEqual(routeProvider.calls.count, 1)
    }

    // MARK: - Driving

    private func start() throws {
        locationProvider.lastLocation = fix(at: Self.a)
        try core.startNavigation(route: hairpin)
    }

    private func fix(at coordinate: CLLocationCoordinate2D, accuracy: Double = 5) -> UserLocation {
        tick += 1
        return UserLocation(
            coordinates: GeographicCoordinate(coordinate),
            horizontalAccuracy: accuracy,
            courseOverGround: nil,
            timestamp: Date(timeIntervalSince1970: tick),
            speed: nil
        )
    }

    /// Pushes one fix and returns the state the core published for it. The
    /// subscription is in place before the push, and the fix is matched by its
    /// timestamp, so nothing here depends on timing.
    @discardableResult
    private func drive(
        to location: UserLocation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> NavigationState? {
        let published = expectation(description: "state for fix at t=\(location.timestamp.timeIntervalSince1970)")
        var captured: NavigationState?
        core.$state
            .compactMap { $0 }
            .filter { $0.rawUserLocation?.timestamp == location.timestamp }
            .first()
            .sink { state in
                captured = state
                published.fulfill()
            }
            .store(in: &cancellables)

        locationProvider.push(location)
        await fulfillment(of: [published], timeout: 5)
        XCTAssertNotNil(captured, "the core published no state for this fix", file: file, line: line)
        return captured
    }

    private func expectCalculatingFlagToRiseAndFall() -> [XCTestExpectation] {
        let rose = expectation(description: "isCalculatingNewRoute became true")
        let fell = expectation(description: "isCalculatingNewRoute returned to false")
        var hasRisen = false
        core.$state
            .compactMap { $0?.isCalculatingNewRoute }
            .removeDuplicates()
            .sink { calculating in
                if calculating {
                    hasRisen = true
                    rose.fulfill()
                } else if hasRisen {
                    fell.fulfill()
                }
            }
            .store(in: &cancellables)
        return [rose, fell]
    }

    // MARK: - Geometry helpers

    private static func step(
        _ geometry: [CLLocationCoordinate2D],
        _ maneuverType: String,
        _ modifier: String?,
        _ instruction: String,
        _ roadName: String
    ) -> OSRMFixture.Step {
        OSRMFixture.Step(
            geometry: geometry,
            maneuverType: maneuverType,
            modifier: modifier,
            instruction: instruction,
            roadName: roadName,
            distanceMeters: OSRMFixture.distance(from: geometry[0], to: geometry[1])
        )
    }

    /// `steps` points after `from`, evenly spaced, ending on `to`.
    private static func between(
        _ from: CLLocationCoordinate2D,
        _ to: CLLocationCoordinate2D,
        steps: Int
    ) -> [CLLocationCoordinate2D] {
        (1 ... steps).map { index in
            let fraction = Double(index) / Double(steps)
            return CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                longitude: from.longitude + (to.longitude - from.longitude) * fraction
            )
        }
    }
}

// MARK: - Fakes

private final class FakeLocationProvider: LocationProviding {
    weak var delegate: LocationManagingDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var lastLocation: UserLocation?
    var lastHeading: Heading?
    private(set) var isUpdating = false

    func startUpdating() { isUpdating = true }
    func stopUpdating() { isUpdating = false }

    func push(_ location: UserLocation) {
        lastLocation = location
        delegate?.locationManager(self, didUpdateLocations: [location])
    }
}

/// Answers every request with the same routes and remembers what it was asked.
/// `getRoutes` runs on the core's reroute task, so the record is locked.
private final class FakeRouteProvider: CustomRouteProvider, @unchecked Sendable {
    struct Call {
        let userLocation: UserLocation
        let waypoints: [Waypoint]
    }

    private let routes: [Route]
    private let record = OSAllocatedUnfairLock(initialState: [Call]())

    init(routes: [Route]) {
        self.routes = routes
    }

    var calls: [Call] { record.withLock { $0 } }

    func getRoutes(userLocation: UserLocation, waypoints: [Waypoint]) async throws -> [Route] {
        record.withLock { $0.append(Call(userLocation: userLocation, waypoints: waypoints)) }
        return routes
    }
}

/// `loadedAlternateRoutes` arrives on the reroute task, not the main queue, so
/// the record is locked and the signal is an expectation rather than a flag.
private final class RecordingDelegate: FerrostarCoreDelegate, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (deviations: [DeviationKind](), alternates: [[Route]]()))
    nonisolated(unsafe) var onAlternates: (() -> Void)?

    var deviations: [DeviationKind] { state.withLock { $0.deviations } }
    var alternates: [[Route]] { state.withLock { $0.alternates } }

    func core(_: FerrostarCore, didStartWith _: Route) {}

    func core(
        _: FerrostarCore,
        correctiveActionForDeviation deviation: DeviationKind,
        remainingWaypoints waypoints: [Waypoint]
    ) -> CorrectiveAction {
        state.withLock { $0.deviations.append(deviation) }
        return .getNewRoutes(waypoints: waypoints)
    }

    func core(_: FerrostarCore, loadedAlternateRoutes routes: [Route]) {
        state.withLock { $0.alternates.append(routes) }
        onAlternates?()
    }
}

/// Counts what reaches the network session before handing it to the loader the
/// app ships, which throws.
private final class RequestLoaderSpy: URLRequestLoading, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private let inner = NoNetworkRequestLoader()

    var requests: Int { count.withLock { $0 } }

    func loadData(with request: URLRequest) async throws -> (Data, URLResponse) {
        count.withLock { $0 += 1 }
        return try await inner.loadData(with: request)
    }
}

private final class NoOpSpeechSynthesizer: SpeechSynthesizer {
    var isSpeaking: Bool { false }
    func speak(_: AVSpeechUtterance) {}
    func stopSpeaking(at _: AVSpeechBoundary) -> Bool { true }
}

// MARK: - State access

private extension NavigationState {
    var rawUserLocation: UserLocation? {
        switch tripState {
        case let .navigating(_, userLocation, _, _, _, _, _, _, _, _, _):
            userLocation
        case let .complete(userLocation, _):
            userLocation
        case let .idle(userLocation):
            userLocation
        }
    }

    var isComplete: Bool {
        if case .complete = tripState { return true }
        return false
    }
}

private extension GeographicCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(lat: coordinate.latitude, lng: coordinate.longitude)
    }
}
