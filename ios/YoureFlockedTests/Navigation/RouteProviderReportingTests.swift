import CoreLocation
import FerrostarCoreFFI
import os
import XCTest
@testable import YoureFlocked

/// Coordinates are synthetic sub-0.01-degree offsets from the null island.
final class RouteProviderReportingTests: XCTestCase {

    func testReportsFailureBeforeThrowingWhenThereIsNoDestination() async {
        let reported = OSAllocatedUnfairLock(initialState: [String]())
        let provider = FlckdRouteProvider(
            routing: ValhallaRoutingService(),
            options: RoutePlanOptions(
                avoidanceLevel: .balanced,
                useFOV: false,
                costing: "auto",
                useMetric: true
            ),
            cameras: { _ in [] },
            planned: { result in
                reported.withLock { outcomes in
                    switch result {
                    case .success: outcomes.append("success")
                    case .failure: outcomes.append("failure")
                    }
                }
            }
        )

        do {
            _ = try await provider.getRoutes(userLocation: userLocation(), waypoints: [])
            XCTFail("a request with no destination cannot produce a route")
        } catch {
            XCTAssertEqual(error as? NavigationError, .noWaypoints)
        }

        XCTAssertEqual(
            reported.withLock { $0 },
            ["failure"],
            "the session controller clears its rerouting flag from this callback, so every exit has to report exactly once"
        )
    }

    private func userLocation() -> UserLocation {
        UserLocation(
            coordinates: GeographicCoordinate(lat: 0.0, lng: 0.0),
            horizontalAccuracy: 5,
            courseOverGround: CourseOverGround(degrees: 90, accuracy: 5),
            timestamp: Date(timeIntervalSince1970: 0),
            speed: nil
        )
    }
}
