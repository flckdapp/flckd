import CoreLocation
import Foundation
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// Feeds FerrostarCore from the app's existing `LocationManager`.
///
/// Ferrostar ships `CoreLocationProvider`, but using it would mean a second
/// `CLLocationManager` with its own authorization prompt and its own settings.
/// There is one location manager in this app and proximity warning depends on
/// it, so `startUpdating()`/`stopUpdating()` switch that manager between
/// navigation and idle delivery rather than turning it on and off.
final class NavigationLocationAdapter: LocationProviding {

    /// Weak on purpose: FerrostarCore assigns itself here and holds this
    /// adapter, so a strong reference would be a retain cycle that outlives
    /// the session.
    weak var delegate: LocationManagingDelegate?

    private let locationManager: LocationManager

    init(locationManager: LocationManager) {
        self.locationManager = locationManager
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    var lastLocation: UserLocation? {
        locationManager.currentLocation.map { UserLocation(clLocation: $0) }
    }

    var lastHeading: Heading? {
        locationManager.heading.flatMap { Heading(clHeading: $0) }
    }

    func startUpdating() {
        locationManager.setNavigationMode(true)
        locationManager.navigationSink = { [weak self] location in
            guard let self else { return }
            self.delegate?.locationManager(self, didUpdateLocations: [UserLocation(clLocation: location)])
        }
        locationManager.headingSink = { [weak self] heading in
            guard let self, let value = Heading(clHeading: heading) else { return }
            self.delegate?.locationManager(self, didUpdateHeading: value)
        }
    }

    func stopUpdating() {
        locationManager.navigationSink = nil
        locationManager.headingSink = nil
        locationManager.setNavigationMode(false)
    }
}
