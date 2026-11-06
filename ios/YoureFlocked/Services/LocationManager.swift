import Foundation
import CoreLocation
import Observation

@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {

    // MARK: - Published State

    var currentLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var locationError: Error?
    var isTracking: Bool = false
    var isLocationPaused: Bool = false
    var heading: CLHeading?

    // MARK: - Configuration

    /// The key Settings' slider writes through `@AppStorage`. Named so the
    /// slider and the seeding in `init` can't drift apart on a typo.
    static let alertRadiusKey = "alertRadius"

    var alertRadius: CLLocationDistance = 200
    var distanceFilter: CLLocationDistance = 25

    /// Mirrors the `CLLocationManager` setting of the same name, which is
    /// write-only from outside, so navigation mode can be seen to have
    /// taken effect.
    private(set) var pausesLocationUpdatesAutomatically: Bool = true

    /// Distance filter while a guidance session is running. Turn-by-turn needs
    /// finer updates than proximity alerting does, and iOS must not pause them
    /// when the car stops at a light.
    static let navigationDistanceFilter: CLLocationDistance = 10
    static let idleDistanceFilter: CLLocationDistance = 25

    // MARK: - Callbacks

    var onProximityEnter: ((SurveillanceCamera, CLLocationDistance) -> Void)?

    /// Set by the guidance session's location adapter. Kept out of observation
    /// because assigning a closure is not a state change any view should
    /// re-render for.
    @ObservationIgnored var navigationSink: ((CLLocation) -> Void)?
    @ObservationIgnored var headingSink: ((CLHeading) -> Void)?

    // MARK: - Private

    private let manager = CLLocationManager()
    private var hasRequestedAlways: Bool = false

    /// Whether some screen asked for heading updates, so leaving navigation
    /// mode doesn't switch off the compass the map is still using.
    private var headingRequested: Bool = false

    override init() {
        super.init()
        // Same trap as the fetch radius: Settings pushed this on change and
        // nothing read it back, so a user who widened their alert radius got
        // the 200 m default again on the next launch while Settings showed
        // the wider value. This one decides whether a warning fires at all.
        let storedAlertRadius = UserDefaults.standard.double(forKey: Self.alertRadiusKey)
        if storedAlertRadius > 0 { alertRadius = storedAlertRadius }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = distanceFilter
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = true
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() {
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse where !hasRequestedAlways:
            hasRequestedAlways = true
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: - Fine Tracking (GPS)

    func startTracking() {
        // Don't call CLLocationManager.locationServicesEnabled() here: it
        // makes a blocking XPC call and Xcode flags it for main-thread
        // unresponsiveness. If services are disabled system-wide, Core
        // Location reports CLError.denied via didFailWithError instead.
        manager.startUpdatingLocation()
        isTracking = true
        isLocationPaused = false
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        isTracking = false
        isLocationPaused = false
    }

    // MARK: - Navigation Mode

    /// Tightens location delivery for turn-by-turn guidance and restores the
    /// proximity-alerting defaults afterwards.
    ///
    /// Deliberately does not start or stop the shared `CLLocationManager`:
    /// proximity warning is the app's primary job and must keep running
    /// whether or not a route is being navigated.
    func setNavigationMode(_ active: Bool) {
        distanceFilter = active ? Self.navigationDistanceFilter : Self.idleDistanceFilter
        manager.distanceFilter = distanceFilter
        pausesLocationUpdatesAutomatically = !active
        manager.pausesLocationUpdatesAutomatically = pausesLocationUpdatesAutomatically
        if active {
            manager.startUpdatingHeading()
        } else if !headingRequested {
            manager.stopUpdatingHeading()
        }
    }

    // MARK: - Heading (independent of tracking)

    func startHeading() {
        headingRequested = true
        manager.startUpdatingHeading()
    }

    func stopHeading() {
        headingRequested = false
        manager.stopUpdatingHeading()
        heading = nil
    }

    // MARK: - Proximity Check

    func checkProximity(to cameras: [SurveillanceCamera]) -> [(camera: SurveillanceCamera, distance: CLLocationDistance)] {
        guard let location = currentLocation else { return [] }

        return cameras.compactMap { camera in
            let cameraLocation = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
            let distance = location.distance(from: cameraLocation)
            guard distance <= alertRadius else { return nil }
            return (camera: camera, distance: distance)
        }
        .sorted { $0.distance < $1.distance }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        ingest(location)

        // iOS auto-pauses fine GPS when the user is stationary
        // (pausesLocationUpdatesAutomatically) and never restarts it on its
        // own. Significant-location-change monitoring keeps running, so a
        // location arriving while paused means the user is moving again.
        // Restart fine updates so proximity alerts resume without the user
        // having to open the app.
        if isLocationPaused, isTracking {
            manager.startUpdatingLocation()
            isLocationPaused = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        ingest(newHeading)
    }

    /// The state update half of the delegate callbacks, separated from the
    /// `CLLocationManager` bookkeeping so a test can feed a fix in without
    /// Core Location running.
    func ingest(_ location: CLLocation) {
        currentLocation = location
        locationError = nil
        navigationSink?(location)
    }

    func ingest(_ newHeading: CLHeading) {
        heading = newHeading
        headingSink?(newHeading)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // CLError.denied covers both app-level denial and the system-wide
        // Location Services toggle being off, so map both to servicesDisabled.
        if (error as? CLError)?.code == .denied {
            locationError = LocationError.servicesDisabled
        } else {
            locationError = error
        }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        isLocationPaused = true
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        isLocationPaused = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            startTracking()
        case .authorizedWhenInUse:
            startTracking()
            if !hasRequestedAlways {
                hasRequestedAlways = true
                manager.requestAlwaysAuthorization()
            }
        case .denied, .restricted:
            stopTracking()
        default:
            break
        }
    }
}

// MARK: - Location Errors

enum LocationError: LocalizedError {
    case servicesDisabled
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .servicesDisabled: return "Location services are disabled. Enable them in Settings."
        case .authorizationDenied: return "Location access denied. Enable in Settings > Privacy > Location."
        }
    }
}
