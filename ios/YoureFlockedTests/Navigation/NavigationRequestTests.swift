import XCTest
@testable import YoureFlocked

final class NavigationRequestTests: XCTestCase {

    /// Mirrors what `buildRequest` emits, with synthetic coordinates.
    private let planningRequest: [String: Any] = [
        "locations": [
            ["lat": 0.0, "lon": 0.0, "type": "break"],
            ["lat": 0.002, "lon": 0.001, "type": "break"],
        ],
        "costing": "auto",
        "directions_options": ["units": "kilometers"],
        "alternates": 2,
        "exclude_polygons": [[[0.0005, 0.0005], [0.0006, 0.0005], [0.0006, 0.0006]]],
    ]

    private func transform(useMetric: Bool) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: planningRequest)
        let output = try ValhallaRoutingService.navigationRequest(from: input, useMetric: useMetric)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    func testAsksForOSRMWithGuidanceInstructions() throws {
        let request = try transform(useMetric: true)

        XCTAssertEqual(request["format"] as? String, "osrm")
        XCTAssertEqual(request["banner_instructions"] as? Bool, true)
        XCTAssertEqual(request["voice_instructions"] as? Bool, true)
        XCTAssertEqual(request["shape_format"] as? String, "polyline6")
    }

    func testMapsUseMetricToUnits() throws {
        XCTAssertEqual(try transform(useMetric: true)["units"] as? String, "kilometers")
        XCTAssertEqual(try transform(useMetric: false)["units"] as? String, "miles")
    }

    /// Valhalla copies `directions_options/units` to the top level with an
    /// appending `AddMember`, so leaving the nested copy in place would make
    /// which `units` wins depend on member order.
    func testDropsTheDeprecatedDirectionsOptions() throws {
        let request = try transform(useMetric: false)

        XCTAssertNil(request["directions_options"])
    }

    func testPreservesThePlanThatProducedTheRoute() throws {
        let request = try transform(useMetric: true)

        XCTAssertEqual(request["costing"] as? String, "auto")
        XCTAssertEqual(request["alternates"] as? Int, 2)

        let locations = try XCTUnwrap(request["locations"] as? [[String: Any]])
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(locations[0]["type"] as? String, "break")
        XCTAssertEqual(locations[1]["lat"] as? Double, 0.002)

        let polygons = try XCTUnwrap(request["exclude_polygons"] as? [[[Double]]])
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(polygons[0].count, 3)
    }

    func testRejectsPayloadThatIsNotAnObject() {
        let notAnObject = Data("[1, 2, 3]".utf8)

        XCTAssertThrowsError(try ValhallaRoutingService.navigationRequest(from: notAnObject, useMetric: true))
    }
}
