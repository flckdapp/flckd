import CoreLocation
import XCTest
@testable import YoureFlocked

final class CameraObservabilityTests: XCTestCase {
    private func point(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: north / 111_320, longitude: east / 111_320)
    }
    private func camera(_ east: Double, _ north: Double, direction: String? = nil, alias: Bool = false) -> SurveillanceCamera {
        let p = point(east, north)
        var tags = ["surveillance:type": "ALPR", "brand": "Flock"]
        if let direction { tags[alias ? "camera:direction" : "direction"] = direction }
        return SurveillanceCamera(osmID: 1, latitude: p.latitude, longitude: p.longitude, tags: tags)
    }
    private var highway: [CLLocationCoordinate2D] { [point(-150, 0), point(150, 0)] }

    func testHighwayShoulderFacingOncomingTrafficIsExposed() {
        let c = camera(0, 5, direction: "270")
        XCTAssertFalse(CameraObservability.windows(camera: c, path: highway).isEmpty)
        XCTAssertTrue(CameraObservability.canObserve(camera: c, position: point(-20, 0), course: 90))
        XCTAssertFalse(CameraObservability.canObserve(camera: c, position: point(20, 0), course: 90))
    }

    func testSideStreetAndUnderpassFacingCrossingRoadStaySilent() {
        XCTAssertTrue(CameraObservability.windows(camera: camera(0, 60, direction: "180"), path: highway).isEmpty)
        XCTAssertTrue(CameraObservability.windows(camera: camera(0, 0, direction: "0"), path: highway).isEmpty)
        XCTAssertFalse(CameraObservability.canObserve(camera: camera(0, 0, direction: "0"), position: point(0, 10), course: 90))
    }

    func testUndirectedNeedsCloseSustainedStretch() {
        XCTAssertFalse(CameraObservability.windows(camera: camera(0, 20), path: highway).isEmpty)
        XCTAssertTrue(CameraObservability.windows(camera: camera(0, 50), path: highway).isEmpty)
        XCTAssertTrue(CameraObservability.windows(camera: camera(0, 0), path: highway).isEmpty,
                      "an undirected centerline crossing is ambiguous, not a shoulder pass")
        XCTAssertTrue(CameraObservability.windows(camera: camera(0, 24), path: highway).isEmpty,
                      "a grazing near-tangent pass lacks thirty metres of exposure")
        XCTAssertTrue(CameraObservability.windows(camera: camera(0, 0), path: [point(-5, 0), point(5, 0)]).isEmpty)
    }

    func testAliasRangesAndMultipleDirectionsReuseModelWedge() {
        XCTAssertFalse(CameraObservability.windows(camera: camera(0, 5, direction: "250-290", alias: true), path: highway).isEmpty)
        XCTAssertFalse(CameraObservability.windows(camera: camera(0, 5, direction: "0;270"), path: highway).isEmpty)
        XCTAssertTrue(CameraObservability.windows(camera: camera(0, 5, direction: "unknown"), path: highway).isEmpty)
    }

    func testRouteExposureOnlyPermitsUpcomingWindowAndPassingInsideView() throws {
        let c = camera(0, 5, direction: "270")
        let exposure = CameraObservability.RouteExposure.build(path: highway, cameras: [c])
        let window = try XCTUnwrap(exposure.windowsByCamera[c.id]?.first)
        XCTAssertTrue(exposure.permits(camera: c, progress: window.start - 100, alertRadius: 200, passing: false,
                                       position: point(-120, 0), course: 90))
        XCTAssertFalse(exposure.permits(camera: c, progress: window.start - 250, alertRadius: 200, passing: false,
                                        position: point(-120, 0), course: 90))
        XCTAssertFalse(exposure.permits(camera: c, progress: window.end + 1, alertRadius: 200, passing: false,
                                        position: point(10, 0), course: 90))
        XCTAssertTrue(exposure.permits(camera: c, progress: 130, alertRadius: 200, passing: true,
                                       position: point(-20, 0), course: 90))
        XCTAssertFalse(exposure.permits(camera: c, progress: 130, alertRadius: 200, passing: true,
                                        position: point(-80, 0), course: 90))
    }

    func testRerouteRebuildReplacesExposedSet() {
        let c = camera(0, 5, direction: "270")
        let first = CameraObservability.RouteExposure.build(path: highway, cameras: [c])
        let rerouted = CameraObservability.RouteExposure.build(path: [point(-150, 80), point(150, 80)], cameras: [c])
        XCTAssertNotNil(first.windowsByCamera[c.id])
        XCTAssertNil(rerouted.windowsByCamera[c.id])
    }

    func testUnnavigatedTrackAndCourseRejectCrossRoad() {
        let c = camera(0, 5, direction: "270")
        var track = CameraSpeechTrack()
        func fix(_ east: Double, _ north: Double, course: Double, t: Double) -> CLLocation {
            CLLocation(coordinate: point(east, north), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                       course: course, speed: 10, timestamp: Date(timeIntervalSince1970: t))
        }
        let a = fix(-32, 0, course: 90, t: 1), b = fix(-15, 0, course: 90, t: 2)
        track.append(a); track.append(b)
        XCTAssertTrue(track.permits(c, at: b))
        XCTAssertFalse(track.permits(camera(0, 60, direction: "180"), at: b))
        XCTAssertFalse(track.permits(camera(-15, 0, direction: "0"), at: b))
        XCTAssertFalse(track.permits(c, at: fix(-15, 0, course: -1, t: 3)))
    }

    func testUnnavigatedUndirectedCameraRequiresThirtyMeterTrackAtCloseRange() throws {
        var track = CameraSpeechTrack()
        let c = camera(0, 20)
        for (index, east) in [-14.0, -7, 0, 7, 14].enumerated() {
            let fix = CLLocation(coordinate: point(east, 0), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                                 course: 90, speed: 5, timestamp: Date(timeIntervalSince1970: Double(index + 1)))
            track.append(fix)
        }
        let last = try XCTUnwrap(track.fixes.last)
        XCTAssertTrue(track.permits(c, at: last))
        XCTAssertFalse(track.permits(camera(0, 50), at: last))
    }

    func testDenseAndSparseRouteGeometryAgree() {
        let c = camera(0, 20)
        let dense = stride(from: -150.0, through: 150, by: 5).map { point($0, 0) }
        XCTAssertEqual(CameraObservability.windows(camera: c, path: highway).isEmpty,
                       CameraObservability.windows(camera: c, path: dense).isEmpty)
    }

    func testQueuedSpeechRevalidatesExposureAndCountsOnlyEligibleGroup() {
        var queue = VoicePromptQueue()
        let group = VoiceUtterance(clips: ["cam.cameras_ahead_2"], priority: .camera, kind: .camera(.flock),
                                   createdAt: 0, cameraTargets: [1, 2])
        let passing = VoiceUtterance(clips: ["cam.flock.passing"], priority: .camera, kind: .camera(.flock),
                                     createdAt: 0, cameraTargets: [1], cameraRequiresView: true)
        queue.enqueue(group); queue.enqueue(passing)
        queue.removeInvalidCameras(CameraSpeechEligibility(entry: [1, 2], passing: [1]))
        XCTAssertEqual(queue.pending.count, 2)
        queue.removeInvalidCameras(CameraSpeechEligibility(entry: [1], passing: []))
        XCTAssertTrue(queue.pending.isEmpty, "a side-street camera cannot survive in a grouped prompt")
    }

    func testShortTrackExpiresAndRejectsPoorAccuracyAndTeleport() {
        let c = camera(0, 5, direction: "270")
        func fix(_ east: Double, t: Double, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: point(east, 0), altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                       course: 90, speed: 10, timestamp: Date(timeIntervalSince1970: t))
        }
        var track = CameraSpeechTrack()
        track.append(fix(-32, t: 1))
        track.append(fix(-15, t: 2))
        XCTAssertTrue(track.permits(c, at: fix(-15, t: 2)))
        track.append(fix(-15, t: 20))
        XCTAssertFalse(track.permits(c, at: fix(-15, t: 20)))
        track.append(fix(-10, t: 21, accuracy: 100))
        XCTAssertTrue(track.fixes.isEmpty)
        track.append(fix(-1000, t: 22))
        track.append(fix(-15, t: 23))
        XCTAssertFalse(track.permits(c, at: fix(-15, t: 23)))
    }

    func testDifferentViewAndAxisEntriesCannotCombineToPermitCrossing() {
        let c = camera(0, 0, direction: "0;90")
        XCTAssertFalse(CameraObservability.canObserve(camera: c, position: point(0, 20), course: 90))
    }

    @MainActor
    func testSpeechPredicateDoesNotChangeVisualNearCameraAlert() {
        let sideStreet = camera(0, 60, direction: "180")
        let store = CameraStore()
        store.cameras = [sideStreet]
        store.lastFetchBounds = BoundingBox(south: -0.01, west: -0.01, north: 0.01, east: 0.01)
        let engine = ProximityAlertEngine()
        let location = CLLocation(coordinate: point(0, 0), altitude: 0, horizontalAccuracy: 5,
                                  verticalAccuracy: -1, course: 90, speed: 20, timestamp: Date())
        engine.handleLocationUpdate(location: location, heading: nil, cameraStore: store,
                                    notificationManager: NotificationManager(), liveActivityManager: nil,
                                    alertRadius: 200, alertMode: .nearCamera, enableHaptics: false)
        XCTAssertEqual(engine.activeAlert?.cameraID, sideStreet.id)
        XCTAssertTrue(CameraObservability.windows(camera: sideStreet, path: highway).isEmpty)
        XCTAssertEqual(store.nearbyCameras.count, 1)
    }
}
