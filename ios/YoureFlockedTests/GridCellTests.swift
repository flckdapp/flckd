import XCTest
import CoreLocation
@testable import YoureFlocked

/// All coordinates here are synthetic grid points, not places.
final class GridCellTests: XCTestCase {

    private let here = CLLocationCoordinate2D(latitude: 40.2, longitude: -75.7)

    func testTwoPositionsInSameCellProduceIdenticalRequests() {
        let movedAbout300m = CLLocationCoordinate2D(
            latitude: here.latitude + 0.0027,
            longitude: here.longitude + 0.0036
        )
        let a = GridCell(containing: here)
        let b = GridCell(containing: movedAbout300m)

        XCTAssertEqual(a, b)
        XCTAssertEqual(
            OverpassService.query(for: a, kind: .speed),
            OverpassService.query(for: b, kind: .speed)
        )
    }

    func testRequestBoxIsFourIntegersAndNothingElse() {
        let cell = GridCell(containing: here)

        XCTAssertEqual(cell.overpassBBox, "40,-76,41,-75")
        for kind in [OverpassService.Kind.speed, .all] {
            let query = OverpassService.query(for: cell, kind: kind)
            XCTAssertTrue(query.contains("(40,-76,41,-75)"))
            XCTAssertNil(query.range(of: #"\d\.\d"#, options: .regularExpression),
                         "query must not contain a fractional number: \(query)")
        }
    }

    func testGridIsAnchoredAtTheOriginNotTheUser() {
        let cell = GridCell(containing: here)

        XCTAssertEqual(cell.bounds, BoundingBox(south: 40, west: -76, north: 41, east: -75))
    }

    func testCellCentreDoesNotRevealPosition() {
        let bounds = GridCell(containing: here).bounds
        let centre = CLLocation(
            latitude: (bounds.north + bounds.south) / 2,
            longitude: (bounds.east + bounds.west) / 2
        )
        let truth = CLLocation(latitude: here.latitude, longitude: here.longitude)

        XCTAssertGreaterThan(centre.distance(from: truth), 10_000)
    }

    func testCellShapeIsIndependentOfLatitude() {
        let south = GridCell(containing: CLLocationCoordinate2D(latitude: 25.3, longitude: -75.7)).bounds
        let north = GridCell(containing: CLLocationCoordinate2D(latitude: 49.3, longitude: -75.7)).bounds

        let ratioSouth = (south.east - south.west) / (south.north - south.south)
        let ratioNorth = (north.east - north.west) / (north.north - north.south)
        XCTAssertEqual(ratioSouth, ratioNorth)
    }

    func testBoxInsideOneCellCoversOnlyThatCell() {
        let box = BoundingBox.around(center: here, radiusKm: 5)

        XCTAssertEqual(GridCell.covering(box), [GridCell(lat: 40, lon: -76)])
    }

    func testBoxAcrossAnEdgeCoversBothCells() {
        let nearEdge = CLLocationCoordinate2D(latitude: 40.02, longitude: -75.7)
        let box = BoundingBox.around(center: nearEdge, radiusKm: 5)

        XCTAssertEqual(Set(GridCell.covering(box)), [GridCell(lat: 39, lon: -76), GridCell(lat: 40, lon: -76)])
    }

    func testCoveringAWholeCellExactlyYieldsOneCell() {
        XCTAssertEqual(GridCell.covering(GridCell(lat: 40, lon: -76).bounds), [GridCell(lat: 40, lon: -76)])
    }
}
