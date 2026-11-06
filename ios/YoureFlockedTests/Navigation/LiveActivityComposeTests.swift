import XCTest
@testable import YoureFlocked

/// `LiveActivityManager` itself needs ActivityKit and a real activity, neither
/// of which a unit test can have, so the two decisions worth testing live in
/// plain values: what goes into a payload, and whether a payload is worth
/// pushing at all.
final class LiveActivityComposeTests: XCTestCase {

    private let camera = CameraActivityFields(
        nearbyCameraCount: 2,
        nearestCameraDistance: 180,
        nearestCameraBearing: 95,
        nearestCameraType: "alpr",
        isTracking: true
    )

    private let navigation = NavigationActivityFields(
        maneuverCode: ManeuverType.right.rawValue,
        instruction: "Turn right onto Test Street",
        distanceToNextTurnMeters: 400,
        eta: Date(timeIntervalSinceReferenceDate: 800_000_000),
        isRerouting: false
    )

    // MARK: - Composition

    func testCameraOnlyCompositionLeavesEveryNavigationFieldAbsent() {
        let state = LiveActivityContent.compose(camera: camera, navigation: nil)

        XCTAssertEqual(state.nearbyCameraCount, 2)
        XCTAssertEqual(state.nearestCameraDistance, 180)
        XCTAssertEqual(state.nearestCameraBearing, 95)
        XCTAssertEqual(state.nearestCameraType, "alpr")
        XCTAssertTrue(state.isTracking)

        XCTAssertNil(state.nextManeuverCode)
        XCTAssertNil(state.nextManeuverInstruction)
        XCTAssertNil(state.distanceToNextTurnMeters)
        XCTAssertNil(state.eta)
        XCTAssertNil(state.isRerouting)
        XCTAssertFalse(state.hasNavigation)
    }

    /// The reason composition exists: `ContentState` is replaced wholesale, so a
    /// camera update that carried only camera fields would blank the turn.
    func testACameraUpdateCarriesTheTurnAlongWithIt() {
        let laterCamera = CameraActivityFields(
            nearbyCameraCount: 5,
            nearestCameraDistance: 40,
            nearestCameraBearing: 10,
            nearestCameraType: "speed_camera",
            isTracking: true
        )

        let state = LiveActivityContent.compose(camera: laterCamera, navigation: navigation)

        XCTAssertEqual(state.nearbyCameraCount, 5)
        XCTAssertEqual(state.nearestCameraType, "speed_camera")
        XCTAssertEqual(state.nextManeuverCode, ManeuverType.right.rawValue)
        XCTAssertEqual(state.nextManeuverInstruction, "Turn right onto Test Street")
        XCTAssertEqual(state.distanceToNextTurnMeters, 400)
        XCTAssertTrue(state.hasNavigation)
    }

    /// And the other way round: a turn must not blank the camera warning.
    func testATurnKeepsTheCameraWarningOnScreen() {
        var later = navigation
        later.distanceToNextTurnMeters = 120
        later.instruction = "Turn left onto Example Avenue"
        later.maneuverCode = ManeuverType.left.rawValue

        let state = LiveActivityContent.compose(camera: camera, navigation: later)

        XCTAssertEqual(state.nearbyCameraCount, 2)
        XCTAssertEqual(state.nearestCameraDistance, 180)
        XCTAssertEqual(state.nearestCameraType, "alpr")
        XCTAssertEqual(state.distanceToNextTurnMeters, 120)
    }

    func testReroutingIsAbsentRatherThanFalseWhenNotNavigating() {
        var rerouting = navigation
        rerouting.isRerouting = true

        XCTAssertNil(LiveActivityContent.compose(camera: camera, navigation: nil).isRerouting)
        XCTAssertEqual(
            LiveActivityContent.compose(camera: camera, navigation: navigation).isRerouting,
            false
        )
        XCTAssertEqual(
            LiveActivityContent.compose(camera: camera, navigation: rerouting).isRerouting,
            true
        )
    }

    // MARK: - Throttle

    func testTheFirstUpdateOfATripIsAlwaysPushed() {
        var throttle = NavigationUpdateThrottle()

        XCTAssertTrue(throttle.shouldPush(navigation))
        XCTAssertFalse(throttle.shouldPush(navigation))
    }

    func testANewInstructionIsAlwaysPushed() {
        var throttle = NavigationUpdateThrottle()
        XCTAssertTrue(throttle.shouldPush(navigation))

        var next = navigation
        next.instruction = "Turn left onto Example Avenue"
        next.maneuverCode = ManeuverType.left.rawValue

        XCTAssertTrue(throttle.shouldPush(next))
    }

    /// Inside 200 m the buckets are 25 m, because that is where the number is
    /// changing fastest and being read hardest.
    func testADistanceInsideTheSameCloseInBucketIsDropped() {
        var throttle = NavigationUpdateThrottle()
        XCTAssertTrue(throttle.shouldPush(withDistance: 170))

        XCTAssertFalse(throttle.shouldPush(withDistance: 162))
        XCTAssertFalse(throttle.shouldPush(withDistance: 151))
        XCTAssertTrue(throttle.shouldPush(withDistance: 149))
    }

    func testTheBucketIsTwiceAsWideFurtherOut() {
        var throttle = NavigationUpdateThrottle()
        XCTAssertTrue(throttle.shouldPush(withDistance: 940))

        XCTAssertFalse(throttle.shouldPush(withDistance: 920))
        XCTAssertFalse(throttle.shouldPush(withDistance: 901))
        XCTAssertTrue(throttle.shouldPush(withDistance: 899))

        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 174), 150)
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 175), 175)
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 949), 900)
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 950), 950)
    }

    /// Two bucket sizes meeting in the middle must not produce the same bucket:
    /// with plain indices, 190 m and 350 m would collide and the update that
    /// crossed between them would be dropped.
    func testTheTwoBucketSizesDoNotCollide() {
        XCTAssertNotEqual(
            NavigationUpdateThrottle.distanceBucket(forMeters: 190),
            NavigationUpdateThrottle.distanceBucket(forMeters: 350)
        )
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 190), 175)
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 350), 350)
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 199), 175)
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: 200), 200)
        XCTAssertNil(NavigationUpdateThrottle.distanceBucket(forMeters: nil))
        XCTAssertNil(NavigationUpdateThrottle.distanceBucket(forMeters: .nan))
        XCTAssertEqual(NavigationUpdateThrottle.distanceBucket(forMeters: -5), 0)
    }

    func testANewArrivalMinuteIsPushed() {
        var throttle = NavigationUpdateThrottle()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(throttle.shouldPush(withETA: base))

        XCTAssertFalse(throttle.shouldPush(withETA: base.addingTimeInterval(20)))
        XCTAssertTrue(throttle.shouldPush(withETA: base.addingTimeInterval(90)))
    }

    func testAnArrivalTimeAppearingOrGoingAwayIsPushed() {
        var throttle = NavigationUpdateThrottle()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(throttle.shouldPush(withETA: nil))

        XCTAssertTrue(throttle.shouldPush(withETA: base))
        XCTAssertTrue(throttle.shouldPush(withETA: nil))
    }

    /// The reroute spinner is the one thing a driver watches for when the route
    /// stops making sense, so it never waits for a bucket.
    func testTheRerouteFlagIsPushedBothWays() {
        var throttle = NavigationUpdateThrottle()
        XCTAssertTrue(throttle.shouldPush(navigation))

        var rerouting = navigation
        rerouting.isRerouting = true
        XCTAssertTrue(throttle.shouldPush(rerouting))
        XCTAssertFalse(throttle.shouldPush(rerouting))
        XCTAssertTrue(throttle.shouldPush(navigation))
    }

    func testResettingForgetsWhatIsOnScreen() {
        var throttle = NavigationUpdateThrottle()
        XCTAssertTrue(throttle.shouldPush(navigation))
        XCTAssertFalse(throttle.shouldPush(navigation))

        throttle.reset()

        XCTAssertTrue(throttle.shouldPush(navigation))
    }

    /// A newly requested activity carries its first fields in the request
    /// itself, so the throttle has to be told rather than pushed through.
    func testRecordingAPushMadeElsewhereSuppressesTheNextIdenticalOne() {
        var throttle = NavigationUpdateThrottle()

        throttle.recordPush(of: navigation)

        XCTAssertFalse(throttle.shouldPush(navigation))
    }
}

private extension NavigationUpdateThrottle {

    mutating func shouldPush(withDistance meters: Double) -> Bool {
        var fields = NavigationActivityFields(
            maneuverCode: ManeuverType.right.rawValue,
            instruction: "Turn right onto Test Street",
            eta: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        fields.distanceToNextTurnMeters = meters
        return shouldPush(fields)
    }

    mutating func shouldPush(withETA eta: Date?) -> Bool {
        var fields = NavigationActivityFields(
            maneuverCode: ManeuverType.right.rawValue,
            instruction: "Turn right onto Test Street",
            distanceToNextTurnMeters: 400
        )
        fields.eta = eta
        return shouldPush(fields)
    }
}
