#if DEBUG
import CoreLocation
import XCTest
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

final class DebugLocationSourceTests: XCTestCase {
    func testOverrideSelectsSimulationAndRetainsLatestRealForRestoration() {
        var source = DebugLocationSource<Int>()
        XCTAssertEqual(source.real(1), 1)
        let token = source.begin()
        XCTAssertNil(source.real(2))
        XCTAssertEqual(source.simulated(3, token: token), 3)
        XCTAssertNil(source.simulated(4, token: UUID()))
        XCTAssertEqual(source.end(token), 2)
        XCTAssertNil(source.simulated(5, token: token))
        XCTAssertEqual(source.real(6), 6)
    }

    func testReplacementRejectsStaleGenerationAndStaleStop() {
        var source = DebugLocationSource<Int>()
        _ = source.real(1)
        let old = source.begin()
        let replacement = source.begin()
        XCTAssertNil(source.end(old))
        XCTAssertNil(source.simulated(2, token: old))
        XCTAssertEqual(source.simulated(3, token: replacement), 3)
        XCTAssertNil(source.real(4))
        XCTAssertEqual(source.end(replacement), 4)
    }

    func testStoppingBeforeAnyRealFixReturnsToNoLocation() {
        var source = DebugLocationSource<Int>()
        let token = source.begin()
        XCTAssertEqual(source.simulated(1, token: token), 1)
        XCTAssertNil(source.end(token))
        XCTAssertNil(source.token)
        XCTAssertEqual(source.real(2), 2)
    }

    func testSharedManagerDoesNotEchoSimulatedFixThroughNavigationSink() {
        let manager = LocationManager()
        var forwarded = 0
        manager.navigationSink = { _ in forwarded += 1 }
        let real = CLLocation(latitude: 0, longitude: 0)
        let latestReal = CLLocation(latitude: 0.002, longitude: 0)
        let simulated = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.001, longitude: 0),
                                  altitude: 0, horizontalAccuracy: 0, verticalAccuracy: -1,
                                  course: 90, speed: 31, timestamp: Date(timeIntervalSince1970: 100))
        manager.ingest(real)
        let token = manager.beginSimulatedSource()
        manager.ingestSimulated(simulated, token: token)
        manager.ingest(latestReal)
        XCTAssertEqual(manager.currentLocation, simulated)
        XCTAssertEqual(manager.currentLocation?.speed, 31)
        XCTAssertEqual(manager.currentLocation?.course, 90)
        XCTAssertTrue(manager.simulatedSourceActive)
        XCTAssertEqual(forwarded, 1)
        manager.endSimulatedSource(token)
        XCTAssertEqual(manager.currentLocation, latestReal)
        XCTAssertFalse(manager.simulatedSourceActive)
        XCTAssertEqual(forwarded, 1, "restoring shared state must not reenter guidance")
        manager.ingest(real)
        XCTAssertEqual(forwarded, 2)
    }

    func testStaleSourceCannotReplaceNewSimulationOrRestoreRealFix() {
        let manager = LocationManager()
        let real = CLLocation(latitude: 0.005, longitude: 0.005)
        manager.ingest(real)
        let first = manager.beginSimulatedSource()
        let second = manager.beginSimulatedSource()
        let selected = CLLocation(latitude: 0.001, longitude: 0.001)
        manager.ingestSimulated(selected, token: second)
        manager.endSimulatedSource(first)
        manager.ingestSimulated(CLLocation(latitude: 0.002, longitude: 0.002), token: first)
        XCTAssertEqual(manager.currentLocation, selected)
        XCTAssertTrue(manager.simulatedSourceActive)
        manager.endSimulatedSource(second)
        XCTAssertEqual(manager.currentLocation, real)
    }

    @MainActor
    func testSimulatedFixReachesTheSameProximityPipelineAsRealFix() {
        let manager = LocationManager()
        let store = CameraStore()
        let engine = ProximityAlertEngine()
        let notifications = NotificationManager()
        let camera = SurveillanceCamera(osmID: 1, latitude: 0, longitude: 0.001,
                                        tags: ["surveillance:type": "ALPR", "brand": "Flock"])
        store.cameras = [camera]
        store.lastFetchBounds = BoundingBox(south: -0.01, west: -0.01, north: 0.01, east: 0.01)
        let token = manager.beginSimulatedSource()
        let simulated = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), altitude: 0,
                                  horizontalAccuracy: 0, verticalAccuracy: -1, course: 90, speed: 10, timestamp: Date())
        manager.ingestSimulated(simulated, token: token)
        manager.ingest(CLLocation(latitude: 0.01, longitude: 0.01))
        guard let selected = manager.currentLocation else { XCTFail("simulation must publish a fix"); return }
        engine.handleLocationUpdate(location: selected, heading: manager.heading, cameraStore: store,
                                    notificationManager: notifications, liveActivityManager: nil,
                                    alertRadius: 200, alertMode: .nearCamera, enableHaptics: false)
        XCTAssertEqual(engine.activeAlert?.cameraID, camera.id)
        XCTAssertEqual(engine.activeAlert?.relativeDirection, .ahead)
        XCTAssertEqual(engine.tripStats.alprCount, 1)
        XCTAssertEqual(store.nearbyCameras.count, 1)
        manager.endSimulatedSource(token)
        XCTAssertEqual(manager.currentLocation?.coordinate.latitude, 0.01)
    }

    @MainActor
    func testProviderRestoresRealLocationOnStopAndRouteReplacement() throws {
        let manager = LocationManager()
        let real = CLLocation(latitude: 0.005, longitude: 0.005)
        manager.ingest(real)
        let shape = [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                     CLLocationCoordinate2D(latitude: 0, longitude: 0.001)]
        let route = try XCTUnwrap(FlckdRouteProvider.routes(fromOSRM: OSRMFixture.response(shape: shape)).first)
        let provider = try DebugDriveLocationProvider(route: route, settings: .init(mph: 25), locationManager: manager)
        provider.startUpdating()
        XCTAssertTrue(manager.simulatedSourceActive)
        XCTAssertEqual(manager.currentLocation?.coordinate.latitude, 0)
        provider.stopUpdating()
        XCTAssertFalse(manager.simulatedSourceActive)
        XCTAssertEqual(manager.currentLocation, real)
        provider.startUpdating()
        try provider.replaceRoute(route)
        XCTAssertFalse(manager.simulatedSourceActive)
        XCTAssertEqual(manager.currentLocation, real)
        provider.startUpdating()
        XCTAssertTrue(manager.simulatedSourceActive)
        provider.stopUpdating()
        XCTAssertEqual(manager.currentLocation, real)
    }

    @MainActor
    func testSimulatedStartPublishesSharedFixAndGuidanceExactlyOnce() throws {
        final class Recorder: LocationManagingDelegate {
            var fixes: [UserLocation] = []
            func locationManager(_ manager: LocationProviding, didUpdateLocations locations: [UserLocation]) { fixes += locations }
            func locationManager(_ manager: LocationProviding, didUpdateHeading heading: Heading) {}
            func locationManager(_ manager: LocationProviding, didFailWithError error: Error) { XCTFail(error.localizedDescription) }
        }
        let manager = LocationManager()
        var echoes = 0
        manager.navigationSink = { _ in echoes += 1 }
        let shape = [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                     CLLocationCoordinate2D(latitude: 0, longitude: 0.001)]
        let route = try XCTUnwrap(FlckdRouteProvider.routes(fromOSRM: OSRMFixture.response(shape: shape)).first)
        let provider = try DebugDriveLocationProvider(route: route, settings: .init(mph: 70), locationManager: manager)
        let recorder = Recorder()
        provider.delegate = recorder
        provider.startUpdating()
        XCTAssertEqual(recorder.fixes.count, 1)
        XCTAssertEqual(manager.currentLocation?.coordinate.longitude, recorder.fixes.first?.coordinates.lng)
        XCTAssertEqual(manager.currentLocation?.speed, 70 * 1609.344 / 3600)
        XCTAssertEqual(manager.currentLocation?.timestamp, recorder.fixes.first?.timestamp)
        XCTAssertEqual(echoes, 0)
        provider.stopUpdating()
    }
}
#endif
