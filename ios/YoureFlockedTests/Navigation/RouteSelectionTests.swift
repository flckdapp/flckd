import CoreLocation
import FerrostarCoreFFI
import XCTest
@testable import YoureFlocked

final class RouteSelectionTests: XCTestCase {

    func testPicksTheCandidateIndexWhenTheDistanceMatches() {
        let routes = [route(distance: 1000), route(distance: 2000), route(distance: 3000)]
        let plan = plan(distanceKm: 2.0, candidateIndex: 1)

        XCTAssertEqual(FlckdRouteProvider.select(routes, for: plan)?.distance, 2000)
    }

    func testAcceptsASmallDifferenceAtTheIndex() {
        let routes = [route(distance: 1000), route(distance: 2030)]
        let plan = plan(distanceKm: 2.0, candidateIndex: 1)

        XCTAssertEqual(FlckdRouteProvider.select(routes, for: plan)?.distance, 2030)
    }

    func testFallsBackToTheFirstRouteWhenTheIndexLooksLikeADifferentRoute() {
        let routes = [route(distance: 1000), route(distance: 5000)]
        let plan = plan(distanceKm: 2.0, candidateIndex: 1)

        XCTAssertEqual(FlckdRouteProvider.select(routes, for: plan)?.distance, 1000)
    }

    func testFallsBackToTheFirstRouteWhenTheIndexIsOutOfRange() {
        let routes = [route(distance: 1000)]
        let plan = plan(distanceKm: 1.0, candidateIndex: 4)

        XCTAssertEqual(FlckdRouteProvider.select(routes, for: plan)?.distance, 1000)
    }

    func testReturnsNilForAnEmptyList() {
        XCTAssertNil(FlckdRouteProvider.select([], for: plan(distanceKm: 1.0, candidateIndex: 0)))
    }

    // MARK: - Fixtures

    private func route(distance: Double) -> Route {
        let corner = GeographicCoordinate(lat: 0.0, lng: 0.0)
        return Route(
            geometry: [corner, GeographicCoordinate(lat: 0.001, lng: 0.001)],
            bbox: FerrostarCoreFFI.BoundingBox(sw: corner, ne: GeographicCoordinate(lat: 0.001, lng: 0.001)),
            distance: distance,
            waypoints: [],
            steps: []
        )
    }

    private func plan(distanceKm: Double, candidateIndex: Int) -> RoutePlan {
        RoutePlan(
            route: ValhallaRoute(
                coordinates: [CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)],
                distanceKm: distanceKm,
                timeSeconds: 60,
                maneuvers: []
            ),
            avoidedCount: 0,
            totalCount: 0,
            requestJSON: Data(),
            candidateIndex: candidateIndex
        )
    }
}
