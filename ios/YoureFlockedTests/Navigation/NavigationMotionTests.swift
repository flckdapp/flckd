import CoreLocation
import XCTest
@testable import YoureFlocked

final class NavigationMotionTests: XCTestCase {
    private let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    private let b = CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
    private let c = CLLocationCoordinate2D(latitude: 0.001, longitude: 0.001)

    func testIntervalTracksWallArrivalNotSimulatedTimestamp() throws {
        var motion = NavigationMotion()
        motion.receive(.init(coordinate: a, heading: 0), at: 0, route: [], onRoute: false)
        motion.receive(.init(coordinate: b, heading: 90), at: 1, route: [], onRoute: false)
        XCTAssertEqual(motion.interval, 1)
        let middle = try XCTUnwrap(motion.sample(at: 1.5))
        XCTAssertEqual(middle.coordinate.longitude, 0.0005, accuracy: 0.00001)
        XCTAssertEqual(middle.heading, 45)
        let before = try XCTUnwrap(motion.sample(at: 1.75))
        motion.receive(.init(coordinate: c, heading: 90), at: 1.75, route: [], onRoute: false)
        XCTAssertEqual(motion.interval, 0.75)
        XCTAssertEqual(try XCTUnwrap(motion.sample(at: 1.75)).coordinate.longitude,
                       before.coordinate.longitude)
        motion.receive(.init(coordinate: a, heading: 0), at: 20, route: [], onRoute: false)
        XCTAssertEqual(try XCTUnwrap(motion.sample(at: 20)).coordinate.latitude, a.latitude)
    }

    func testInterpolationFollowsCornerRatherThanCuttingAcrossIt() throws {
        var motion = NavigationMotion()
        motion.receive(.init(coordinate: a, heading: 90), at: 0, route: [a, b, c], onRoute: true)
        motion.receive(.init(coordinate: c, heading: 0), at: 1, route: [a, b, c], onRoute: true)
        let middle = try XCTUnwrap(motion.sample(at: 1.5))
        XCTAssertEqual(middle.coordinate.longitude, b.longitude, accuracy: 0.00001)
        XCTAssertEqual(middle.coordinate.latitude, b.latitude, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(motion.sample(at: 2)).coordinate.latitude, c.latitude, accuracy: 0.00001)
    }

    func testHeadingTakesShortestArcAcrossNorth() {
        XCTAssertEqual(NavigationMotion.heading(from: 350, to: 10, fraction: 0.5), 0)
        XCTAssertEqual(NavigationMotion.heading(from: 10, to: 350, fraction: 0.5), 0)
        XCTAssertEqual(NavigationMotion.heading(from: 90, to: 180, fraction: 0.5), 135)
    }

    func testOffRouteUsesRawFixesAndDuplicateDeliveryDoesNotChangeInterval() throws {
        var motion = NavigationMotion()
        motion.receive(.init(coordinate: a, heading: 90), at: 0, route: [a, b, c], onRoute: false)
        motion.receive(.init(coordinate: c, heading: 90), at: 1, route: [a, b, c], onRoute: false)
        let middle = try XCTUnwrap(motion.sample(at: 1.5))
        XCTAssertEqual(middle.coordinate.latitude, 0.0005, accuracy: 0.00001)
        XCTAssertEqual(middle.coordinate.longitude, 0.0005, accuracy: 0.00001)
        motion.receive(.init(coordinate: c, heading: 90), at: 1.01, route: [a, b, c], onRoute: false)
        XCTAssertEqual(motion.interval, 1)
    }

    func testReportedSpeedBrakingIsSmoothedRatherThanJumpingZoom() {
        var zoom = NavigationZoom()
        for time in 0...30 { _ = zoom.update(speed: 31.3, at: Double(time)) }
        let highway = zoom.distance
        _ = zoom.update(speed: 0, at: 31)
        XCTAssertGreaterThan(zoom.distance, highway - 300)
        _ = zoom.update(speed: 0, at: 32)
        XCTAssertGreaterThan(zoom.distance, 700)
        for time in 33...65 { _ = zoom.update(speed: 0, at: Double(time)) }
        XCTAssertLessThan(zoom.distance, 525)
    }

    func testSwitchingToRawOffRouteDoesNotInventAnOnRoadPath() throws {
        var motion = NavigationMotion()
        motion.receive(.init(coordinate: a, heading: 90), at: 0, route: [a, b, c], onRoute: true)
        motion.receive(.init(coordinate: b, heading: 90), at: 1, route: [a, b, c], onRoute: true)
        let raw = CLLocationCoordinate2D(latitude: 0.0005, longitude: 0.0005)
        motion.receive(.init(coordinate: raw, heading: 90), at: 2, route: [a, b, c], onRoute: false)
        XCTAssertEqual(try XCTUnwrap(motion.sample(at: 2)).coordinate.latitude, raw.latitude, accuracy: 0.00001)
    }

    func testCameraDistanceCurveAndSteadyHighway() {
        func speed(_ mph: Double) -> Double { mph * 1609.344 / 3600 }
        XCTAssertEqual(NavigationZoom.distance(for: speed(0)), 450)
        XCTAssertEqual(NavigationZoom.distance(for: speed(35)), 562.5, accuracy: 0.001)
        XCTAssertEqual(NavigationZoom.distance(for: speed(45)), 762.5, accuracy: 0.001)
        XCTAssertEqual(NavigationZoom.distance(for: speed(70)), 1700)
        var zoom = NavigationZoom()
        for time in 0...60 { _ = zoom.update(speed: speed(70), at: Double(time)) }
        XCTAssertEqual(zoom.distance, 1700, accuracy: 75)
        let previous = zoom.distance
        _ = zoom.update(speed: -1, at: 61)
        _ = zoom.update(speed: .nan, at: 62)
        XCTAssertEqual(zoom.distance, previous, accuracy: 75)
    }

    func testSubsecondFixesRemainContinuousAtHandoff() throws {
        var motion = NavigationMotion()
        motion.receive(.init(coordinate: a, heading: 350), at: 0, route: [], onRoute: false)
        for index in 1...8 {
            let now = Double(index) / 4
            let before = try XCTUnwrap(motion.sample(at: now))
            let point = CLLocationCoordinate2D(latitude: 0, longitude: Double(index) * 0.0001)
            motion.receive(.init(coordinate: point, heading: 10), at: now, route: [], onRoute: false)
            let after = try XCTUnwrap(motion.sample(at: now))
            XCTAssertEqual(after.coordinate.longitude, before.coordinate.longitude, accuracy: 1e-9)
            XCTAssertEqual(after.heading, before.heading, accuracy: 0.001)
            XCTAssertEqual(motion.interval, 0.25)
        }
    }

    func testWalkingFixesRespectTenMeterLocationFilter() throws {
        var motion = NavigationMotion()
        motion.receive(.init(coordinate: a, heading: 0), at: 0, route: [], onRoute: false)
        motion.receive(.init(coordinate: b, heading: 0), at: 3, route: [], onRoute: false)
        XCTAssertEqual(motion.interval, 3)
        XCTAssertTrue(motion.isMoving(at: 5.9))
        let nearEnd = try XCTUnwrap(motion.sample(at: 5.9))
        XCTAssertLessThan(nearEnd.coordinate.longitude, b.longitude)
    }

    func testStopGoDoesNotPumpAndRampOpensGradually() {
        var zoom = NavigationZoom()
        for time in 0...30 {
            _ = zoom.update(speed: time % 2 == 0 ? 0 : 8, at: Double(time))
            XCTAssertEqual(zoom.distance, 450)
        }
        var last = zoom.distance
        for time in 31...60 {
            let current = zoom.update(speed: 31.3, at: Double(time))
            XCTAssertGreaterThanOrEqual(current, last)
            XCTAssertLessThan(current - last, 300)
            last = current
        }
        XCTAssertGreaterThan(last, 1500)
    }
}
