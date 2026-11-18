#if DEBUG
import CoreLocation
import XCTest
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

final class DebugDriveSimulationTests: XCTestCase {
    func testMPHMapsToOneSimulatedSecondPerTickAtEveryWarp() {
        for mph in DebugDriveSimulationSettings.speeds {
            for multiplier in DebugDriveSimulationSettings.multipliers {
                let settings = DebugDriveSimulationSettings(mph: mph, multiplier: multiplier)
                XCTAssertEqual(settings.resampleDistance, Double(mph) * 1609.344 / 3600, accuracy: 0.001)
                XCTAssertEqual(settings.warpFactor, UInt64(multiplier))
                XCTAssertEqual(settings.wallInterval * Double(multiplier), 1)
            }
        }
        XCTAssertEqual(DebugDriveSimulationSettings(mph: 0, multiplier: 0).mph, 35)
        XCTAssertEqual(DebugDriveSimulationSettings(mph: 0, multiplier: 0).multiplier, 1)
    }

    func testUniformSamplingIgnoresDenseOriginalVertices() {
        let settings = DebugDriveSimulationSettings(mph: 25)
        let geometry = [0.0, 0.00001, 0.00003, 0.0001, 0.001].map { GeographicCoordinate(lat: 0, lng: $0) }
        let sampled = settings.sampled(geometry)
        XCTAssertEqual(sampled.first, geometry.first)
        XCTAssertEqual(sampled.last, geometry.last)
        for index in 1..<(sampled.count - 1) {
            XCTAssertEqual(RouteSignals.distance(sampled[index - 1], sampled[index]), settings.resampleDistance, accuracy: 0.02)
        }
        XCTAssertLessThanOrEqual(RouteSignals.distance(sampled[sampled.count - 2], sampled[sampled.count - 1]), settings.resampleDistance)
    }

    func testSpeedStampUsesSimulatedClockAndPreservesCourse() throws {
        let settings = DebugDriveSimulationSettings(mph: 70, multiplier: 8)
        var stamp = DebugDriveSpeedStamp(metersPerSecond: settings.metersPerSecond)
        let a = UserLocation(coordinates: GeographicCoordinate(lat: 0, lng: 0), horizontalAccuracy: 0,
                             courseOverGround: CourseOverGround(degrees: 90, accuracy: 5),
                             timestamp: Date(timeIntervalSince1970: 1000), speed: nil)
        var b = a
        b.coordinates.lng = 0.001
        b.timestamp = a.timestamp.addingTimeInterval(settings.wallInterval)
        let first = try XCTUnwrap(stamp.stamp(a))
        let second = try XCTUnwrap(stamp.stamp(b))
        XCTAssertEqual(first.speed?.value, settings.metersPerSecond)
        XCTAssertEqual(second.speed?.value, settings.metersPerSecond)
        XCTAssertEqual(second.courseOverGround?.degrees, 90)
        XCTAssertEqual(second.timestamp.timeIntervalSince(first.timestamp),
                       RouteSignals.distance(a.coordinates, b.coordinates) / settings.metersPerSecond, accuracy: 0.001)
        XCTAssertNil(stamp.stamp(b), "startUpdating and route completion repeat the current fix")
    }

    @MainActor
    func testProviderInitialLocationReportsConfiguredSpeed() throws {
        let data = try OSRMFixture.response(shape: [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                                  CLLocationCoordinate2D(latitude: 0, longitude: 0.001)])
        let route = try XCTUnwrap(FlckdRouteProvider.routes(fromOSRM: data).first)
        let settings = DebugDriveSimulationSettings(mph: 15, multiplier: 4)
        let provider = try DebugDriveLocationProvider(route: route, settings: settings)
        XCTAssertEqual(provider.lastLocation?.speed?.value, settings.metersPerSecond)
        XCTAssertEqual(provider.lastLocation?.courseOverGround?.degrees, 90)
    }

    @MainActor
    func testActualProviderTicksForwardOnMainActorWithSimulatedSpeed() async throws {
        final class Recorder: LocationManagingDelegate {
            let received: XCTestExpectation
            var locations: [UserLocation] = []
            init(_ received: XCTestExpectation) { self.received = received }
            func locationManager(_ manager: LocationProviding, didUpdateLocations locations: [UserLocation]) {
                XCTAssertTrue(Thread.isMainThread)
                self.locations += locations
                received.fulfill()
            }
            func locationManager(_ manager: LocationProviding, didUpdateHeading heading: Heading) {}
            func locationManager(_ manager: LocationProviding, didFailWithError error: Error) { XCTFail(error.localizedDescription) }
        }
        let data = try OSRMFixture.response(shape: [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                                  CLLocationCoordinate2D(latitude: 0, longitude: 0.001)])
        let route = try XCTUnwrap(FlckdRouteProvider.routes(fromOSRM: data).first)
        let settings = DebugDriveSimulationSettings(mph: 25, multiplier: 8)
        let received = expectation(description: "initial fix and next tick")
        received.expectedFulfillmentCount = 2
        let recorder = Recorder(received)
        let provider = try DebugDriveLocationProvider(route: route, settings: settings)
        provider.delegate = recorder
        provider.startUpdating()
        await fulfillment(of: [received], timeout: 5)
        provider.stopUpdating()
        XCTAssertGreaterThanOrEqual(recorder.locations.count, 2)
        guard recorder.locations.count >= 2 else { return }
        XCTAssertEqual(recorder.locations[1].speed?.value, settings.metersPerSecond)
        XCTAssertEqual(recorder.locations[1].timestamp.timeIntervalSince(recorder.locations[0].timestamp), 1, accuracy: 0.02)
    }
}
#endif
