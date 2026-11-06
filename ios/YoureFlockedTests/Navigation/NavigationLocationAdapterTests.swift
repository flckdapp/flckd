import CoreLocation
import FerrostarCore
import FerrostarCoreFFI
import XCTest
@testable import YoureFlocked

/// Coordinates are synthetic sub-0.01-degree offsets from the null island.
final class NavigationLocationAdapterTests: XCTestCase {

    private final class RecordingDelegate: LocationManagingDelegate {
        var locations: [UserLocation] = []
        var failures: [Error] = []

        func locationManager(_: LocationProviding, didUpdateLocations locations: [UserLocation]) {
            self.locations += locations
        }

        func locationManager(_: LocationProviding, didUpdateHeading _: Heading) {}

        func locationManager(_: LocationProviding, didFailWithError error: Error) {
            failures.append(error)
        }
    }

    func testStartUpdatingEntersNavigationMode() {
        let locationManager = LocationManager()
        let adapter = NavigationLocationAdapter(locationManager: locationManager)

        adapter.startUpdating()

        XCTAssertEqual(locationManager.distanceFilter, 10)
        XCTAssertFalse(locationManager.pausesLocationUpdatesAutomatically)
    }

    func testStartUpdatingForwardsFixesToTheDelegate() {
        let locationManager = LocationManager()
        let adapter = NavigationLocationAdapter(locationManager: locationManager)
        let delegate = RecordingDelegate()
        adapter.delegate = delegate
        adapter.startUpdating()

        locationManager.ingest(CLLocation(latitude: 0.004, longitude: 0.005))

        let forwarded = delegate.locations.last
        XCTAssertNotNil(forwarded)
        XCTAssertEqual(forwarded?.coordinates.lat ?? .nan, 0.004, accuracy: 1e-9)
        XCTAssertEqual(forwarded?.coordinates.lng ?? .nan, 0.005, accuracy: 1e-9)
    }

    func testStopUpdatingRestoresTheIdleSettings() {
        let locationManager = LocationManager()
        let adapter = NavigationLocationAdapter(locationManager: locationManager)
        adapter.startUpdating()

        adapter.stopUpdating()

        XCTAssertEqual(locationManager.distanceFilter, 25)
        XCTAssertTrue(locationManager.pausesLocationUpdatesAutomatically)
    }

    func testStopUpdatingStopsForwarding() {
        let locationManager = LocationManager()
        let adapter = NavigationLocationAdapter(locationManager: locationManager)
        let delegate = RecordingDelegate()
        adapter.delegate = delegate
        adapter.startUpdating()
        adapter.stopUpdating()

        // Counted rather than asserted empty: the shared manager is never
        // stopped, so a real fix may arrive during the test.
        let before = delegate.locations.count
        locationManager.ingest(CLLocation(latitude: 0.004, longitude: 0.005))

        XCTAssertEqual(delegate.locations.count, before)
    }

    func testTheSharedManagerStillTracksAfterStopping() {
        let locationManager = LocationManager()
        let adapter = NavigationLocationAdapter(locationManager: locationManager)
        adapter.startUpdating()
        adapter.stopUpdating()

        // Proximity warning depends on this: leaving navigation must not stop
        // the location updates the rest of the app runs on.
        locationManager.ingest(CLLocation(latitude: 0.006, longitude: 0.007))

        XCTAssertEqual(locationManager.currentLocation?.coordinate.latitude ?? .nan, 0.006, accuracy: 1e-9)
    }

    func testReadsLastLocationThroughTheSharedManager() {
        let locationManager = LocationManager()
        let adapter = NavigationLocationAdapter(locationManager: locationManager)

        XCTAssertNil(adapter.lastLocation)
        locationManager.ingest(CLLocation(latitude: 0.008, longitude: 0.009))

        XCTAssertEqual(adapter.lastLocation?.coordinates.lat ?? .nan, 0.008, accuracy: 1e-9)
        XCTAssertEqual(adapter.authorizationStatus, locationManager.authorizationStatus)
    }
}
