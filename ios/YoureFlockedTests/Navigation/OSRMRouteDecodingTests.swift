import CoreLocation
import FerrostarCoreFFI
import XCTest
@testable import YoureFlocked

/// Coordinates are synthetic offsets from the null island in 0.001 steps, so
/// nothing here names a place.
final class OSRMRouteDecodingTests: XCTestCase {

    private let shape = [
        CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
        CLLocationCoordinate2D(latitude: 0.001, longitude: 0.0),
        CLLocationCoordinate2D(latitude: 0.001, longitude: 0.001),
    ]

    func testDecodesOneRouteWithItsStepsAndGeometry() throws {
        let data = try OSRMFixture.response(shape: shape)

        let routes = try FlckdRouteProvider.routes(fromOSRM: data)

        XCTAssertEqual(routes.count, 1)
        let route = try XCTUnwrap(routes.first)
        XCTAssertEqual(route.geometry.count, shape.count)
        XCTAssertEqual(route.steps.count, 2)
        XCTAssertEqual(route.distance, 222.6, accuracy: 0.001)

        XCTAssertEqual(route.geometry.first?.lat ?? .nan, shape[0].latitude, accuracy: 1e-6)
        XCTAssertEqual(route.geometry.last?.lng ?? .nan, shape[2].longitude, accuracy: 1e-6)
    }

    func testCarriesBannerAndVoiceInstructionsOntoEveryStep() throws {
        let data = try OSRMFixture.response(shape: shape)

        let route = try XCTUnwrap(try FlckdRouteProvider.routes(fromOSRM: data).first)

        for step in route.steps {
            XCTAssertFalse(step.visualInstructions.isEmpty)
            XCTAssertFalse(step.spokenInstructions.isEmpty)
            XCTAssertEqual(step.geometry.count, 2)
        }
    }

    func testMalformedJSONThrows() {
        let garbage = Data("not a routing response".utf8)

        XCTAssertThrowsError(try FlckdRouteProvider.routes(fromOSRM: garbage))
    }

    func testNonOkStatusThrows() throws {
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try OSRMFixture.response(shape: shape)) as? [String: Any]
        )
        payload["code"] = "NoRoute"
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try FlckdRouteProvider.routes(fromOSRM: data))
    }
}
