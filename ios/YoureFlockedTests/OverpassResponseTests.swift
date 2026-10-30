import XCTest
@testable import YoureFlocked

final class OverpassResponseTests: XCTestCase {

    private func decode(_ elements: String) throws -> [SurveillanceCamera] {
        let json = Data(#"{"version":0.6,"elements":[\#(elements)]}"#.utf8)
        return try JSONDecoder().decode(OverpassResponse.self, from: json)
            .elements.compactMap { $0.toSurveillanceCamera() }
    }

    func testSpeedCameraNodeBecomesSpeedCamera() throws {
        let cameras = try decode(#"""
        {"type":"node","id":101,"lat":40.2,"lon":-75.7,"tags":{"highway":"speed_camera"}}
        """#)

        XCTAssertEqual(cameras.map(\.surveillanceType), [.speedCamera])
        XCTAssertEqual(cameras.first?.osmID, 101)
    }

    func testEnforcementRelationBecomesSpeedCamera() throws {
        let cameras = try decode(#"""
        {"type":"relation","id":202,"center":{"lat":40.2,"lon":-75.7},
         "members":[{"type":"node","ref":1,"role":"device"}],
         "tags":{"type":"enforcement","enforcement":"maxspeed","maxspeed":"50"}}
        """#)

        XCTAssertEqual(cameras.map(\.surveillanceType), [.speedCamera])
        XCTAssertEqual(cameras.first?.latitude, 40.2)
    }

    func testBareEnforcementNodeBecomesSpeedCamera() throws {
        let cameras = try decode(#"""
        {"type":"node","id":303,"lat":40.2,"lon":-75.7,"tags":{"enforcement":"maxspeed"}}
        """#)

        XCTAssertEqual(cameras.map(\.surveillanceType), [.speedCamera])
    }

    func testRelationIDCannotCollideWithNodeID() throws {
        let cameras = try decode(#"""
        {"type":"node","id":404,"lat":40.2,"lon":-75.7,"tags":{"highway":"speed_camera"}},
        {"type":"relation","id":404,"center":{"lat":40.3,"lon":-75.6},"tags":{"type":"enforcement"}}
        """#)

        XCTAssertEqual(Set(cameras.map(\.osmID)).count, 2)
        XCTAssertEqual(cameras.last?.osmID, -404)
    }

    func testRelationWithoutCentreIsDropped() throws {
        let cameras = try decode(#"""
        {"type":"relation","id":505,"tags":{"type":"enforcement"}}
        """#)

        XCTAssertEqual(cameras, [])
    }
}
