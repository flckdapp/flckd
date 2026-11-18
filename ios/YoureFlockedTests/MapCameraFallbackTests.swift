import MapKit
import XCTest
@testable import YoureFlocked

@MainActor
final class MapCameraFallbackTests: XCTestCase {
    func testUnavailableLocationNeverAutoFramesChangingAnnotations() {
        let model = MapViewModel()
        XCTAssertEqual(MapViewModel.locationFallback, .rect(.world))
        XCTAssertEqual(model.cameraPosition, .userLocation(followsHeading: true, fallback: .rect(.world)))
        XCTAssertEqual(model.followMode, .followHeading)
        model.cycleFollowMode()
        XCTAssertEqual(model.cameraPosition, .rect(.world))
        XCTAssertEqual(model.followMode, .off)
        model.cycleFollowMode()
        XCTAssertEqual(model.cameraPosition, .userLocation(fallback: .rect(.world)))
        XCTAssertEqual(model.followMode, .follow)
        model.cycleFollowMode()
        XCTAssertEqual(model.cameraPosition, .userLocation(followsHeading: true, fallback: .rect(.world)))
    }

    func testLeavingFollowModePreservesTheViewport() {
        let model = MapViewModel()
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        model.visibleRegion = region
        model.cycleFollowMode()
        XCTAssertEqual(model.cameraPosition.region?.center.latitude, 0)
        XCTAssertEqual(model.cameraPosition.region?.span.latitudeDelta, 0.01)
    }
}
