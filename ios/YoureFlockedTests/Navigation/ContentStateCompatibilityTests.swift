import XCTest
@testable import YoureFlocked

/// ActivityKit keeps the Live Activity's `ContentState` encoded and hands a
/// payload written by the previous build to the new one after an app update. A
/// user mid-drive through that update has the five camera keys on disk and
/// nothing else, and a decode failure takes the camera warning off their lock
/// screen. That is the whole reason the navigation fields are optional, so it is
/// worth a test rather than a comment.
final class ContentStateCompatibilityTests: XCTestCase {

    /// Exactly what the build before this one wrote: no navigation keys at all.
    private let payloadBeforeTurnsExisted = """
    {
      "nearbyCameraCount": 3,
      "nearestCameraDistance": 142.5,
      "nearestCameraBearing": 217.0,
      "nearestCameraType": "alpr",
      "isTracking": true
    }
    """

    func testPayloadWrittenBeforeTurnsExistedStillDecodes() throws {
        let data = Data(payloadBeforeTurnsExisted.utf8)

        let state = try JSONDecoder().decode(
            SurveillanceActivityAttributes.ContentState.self,
            from: data
        )

        XCTAssertEqual(state.nearbyCameraCount, 3)
        XCTAssertEqual(state.nearestCameraDistance, 142.5)
        XCTAssertEqual(state.nearestCameraBearing, 217)
        XCTAssertEqual(state.nearestCameraType, "alpr")
        XCTAssertTrue(state.isTracking)

        XCTAssertNil(state.nextManeuverCode)
        XCTAssertNil(state.nextManeuverInstruction)
        XCTAssertNil(state.distanceToNextTurnMeters)
        XCTAssertNil(state.eta)
        XCTAssertNil(state.isRerouting)
        XCTAssertFalse(state.hasNavigation)
    }

    /// Explicit nulls decode too. ActivityKit's own encoder omits them, but the
    /// payload is only guaranteed to round-trip, not to be written one way.
    func testExplicitNullNavigationKeysDecode() throws {
        let data = Data("""
        {
          "nearbyCameraCount": 0,
          "nearestCameraDistance": -1,
          "nearestCameraBearing": 0,
          "nearestCameraType": "",
          "isTracking": false,
          "nextManeuverCode": null,
          "nextManeuverInstruction": null,
          "distanceToNextTurnMeters": null,
          "eta": null,
          "isRerouting": null
        }
        """.utf8)

        let state = try JSONDecoder().decode(
            SurveillanceActivityAttributes.ContentState.self,
            from: data
        )

        XCTAssertFalse(state.hasNavigation)
        XCTAssertNil(state.eta)
    }

    /// A camera-only state has to encode to the same five keys it always did, or
    /// the compatibility above only works in one direction.
    func testCameraOnlyStateEncodesToTheOriginalFiveKeys() throws {
        let state = SurveillanceActivityAttributes.ContentState(
            nearbyCameraCount: 1,
            nearestCameraDistance: 90,
            nearestCameraBearing: 12,
            nearestCameraType: "speed_camera",
            isTracking: true
        )

        let data = try JSONEncoder().encode(state)
        let keys = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        ).keys

        XCTAssertEqual(
            Set(keys),
            [
                "nearbyCameraCount", "nearestCameraDistance", "nearestCameraBearing",
                "nearestCameraType", "isTracking",
            ]
        )
    }

    func testStateWithNavigationFieldsSurvivesARoundTrip() throws {
        let state = SurveillanceActivityAttributes.ContentState(
            nearbyCameraCount: 2,
            nearestCameraDistance: 310,
            nearestCameraBearing: 275,
            nearestCameraType: "alpr",
            isTracking: true,
            nextManeuverCode: ManeuverType.rampRight.rawValue,
            nextManeuverInstruction: "Take the ramp on the right",
            distanceToNextTurnMeters: 650,
            eta: Date(timeIntervalSinceReferenceDate: 800_000_000),
            isRerouting: false
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            SurveillanceActivityAttributes.ContentState.self,
            from: data
        )

        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.hasNavigation)
        XCTAssertEqual(
            ManeuverType(code: try XCTUnwrap(decoded.nextManeuverCode)),
            .rampRight
        )
    }

    /// A code this build doesn't know must still render, the same way
    /// `ManeuverType(code:)` promises everywhere else.
    func testUnknownManeuverCodeInAPayloadStillRenders() throws {
        let data = Data("""
        {
          "nearbyCameraCount": 0,
          "nearestCameraDistance": -1,
          "nearestCameraBearing": 0,
          "nearestCameraType": "",
          "isTracking": true,
          "nextManeuverCode": 99,
          "nextManeuverInstruction": "Something new"
        }
        """.utf8)

        let state = try JSONDecoder().decode(
            SurveillanceActivityAttributes.ContentState.self,
            from: data
        )

        XCTAssertTrue(state.hasNavigation)
        XCTAssertEqual(ManeuverType(code: try XCTUnwrap(state.nextManeuverCode)), .unknown)
        XCTAssertFalse(ManeuverType.unknown.symbolName.isEmpty)
    }

    func testNavigationIsConsideredAbsentWhenOnlyADistanceArrives() {
        var state = SurveillanceActivityAttributes.ContentState(
            nearbyCameraCount: 0,
            nearestCameraDistance: -1,
            nearestCameraBearing: 0,
            nearestCameraType: "",
            isTracking: true
        )
        state.distanceToNextTurnMeters = 400

        XCTAssertFalse(state.hasNavigation)
    }
}
