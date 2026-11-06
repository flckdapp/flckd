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
        let data = try response(shape: shape)

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
        let data = try response(shape: shape)

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
            try JSONSerialization.jsonObject(with: try response(shape: shape)) as? [String: Any]
        )
        payload["code"] = "NoRoute"
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try FlckdRouteProvider.routes(fromOSRM: data))
    }

    // MARK: - Fixture

    /// The shape of a Valhalla `format: osrm` answer, trimmed to the fields
    /// Ferrostar's parser requires: `intersections` and `components` have no
    /// serde default, so they must be present even when empty.
    private func response(shape: [CLLocationCoordinate2D]) throws -> Data {
        let steps = (0 ..< shape.count - 1).map { index in
            step(
                from: shape[index],
                to: shape[index + 1],
                maneuver: index == 0 ? "depart" : "turn",
                text: index == 0 ? "Head north" : "Turn right"
            )
        }
        let payload: [String: Any] = [
            "code": "Ok",
            "waypoints": [
                ["location": [shape[0].longitude, shape[0].latitude], "name": "Start"],
                ["location": [shape[2].longitude, shape[2].latitude], "name": "Finish"],
            ],
            "routes": [[
                "distance": 222.6,
                "duration": 30.0,
                "geometry": PolylineEncoder.encode(shape),
                "legs": [[
                    "distance": 222.6,
                    "duration": 30.0,
                    "steps": steps,
                ]],
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func step(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        maneuver: String,
        text: String
    ) -> [String: Any] {
        [
            "distance": 111.3,
            "duration": 15.0,
            "geometry": PolylineEncoder.encode([from, to]),
            "name": "Test Street",
            "mode": "drive",
            "maneuver": [
                "location": [from.longitude, from.latitude],
                "bearing_before": 0,
                "bearing_after": 90,
                "type": maneuver,
                "instruction": text,
            ],
            "intersections": [[
                "location": [from.longitude, from.latitude],
                "bearings": [90],
                "entry": [true],
            ]],
            "bannerInstructions": [[
                "distanceAlongGeometry": 111.3,
                "primary": ["text": text, "components": []],
            ]],
            "voiceInstructions": [[
                "distanceAlongGeometry": 111.3,
                "announcement": text,
            ]],
        ]
    }
}
