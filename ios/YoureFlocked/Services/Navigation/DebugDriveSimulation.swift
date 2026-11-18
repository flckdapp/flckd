#if DEBUG
import CoreLocation
import Foundation
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

struct DebugDriveSimulationSettings {
    static let speedKey = "debugSimulatedDriveSpeedMPH"
    static let timeKey = "debugSimulatedDriveTimeMultiplier"
    static let speeds = [15, 25, 35, 45, 55, 70]
    static let multipliers = [1, 2, 4, 8]
    let mph: Int
    let multiplier: Int

    init(mph: Int = 35, multiplier: Int = 1) {
        self.mph = Self.speeds.contains(mph) ? mph : 35
        self.multiplier = Self.multipliers.contains(multiplier) ? multiplier : 1
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> Self {
        Self(mph: defaults.integer(forKey: speedKey), multiplier: defaults.integer(forKey: timeKey))
    }

    var metersPerSecond: Double { Double(mph) * 1609.344 / 3600 }
    var resampleDistance: Double { metersPerSecond }
    var warpFactor: UInt64 { UInt64(multiplier) }
    var wallInterval: TimeInterval { 1 / Double(multiplier) }

    /// Ferrostar only densifies: existing short segments otherwise make speed
    /// depend on the map's vertex density. Sample at uniform path distances
    /// first, then ask its provider to leave those points alone.
    func sampled(_ geometry: [GeographicCoordinate]) -> [GeographicCoordinate] {
        guard let first = geometry.first else { return [] }
        var result = [first]
        var traversed = 0.0
        var target = resampleDistance
        for (a, b) in zip(geometry, geometry.dropFirst()) {
            let length = RouteSignals.distance(a, b)
            guard length > 0 else { continue }
            var delta = b.lng - a.lng
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            while target <= traversed + length {
                let fraction = (target - traversed) / length
                let longitude = a.lng + delta * fraction
                result.append(GeographicCoordinate(
                    lat: a.lat + (b.lat - a.lat) * fraction,
                    lng: longitude > 180 ? longitude - 360 : longitude < -180 ? longitude + 360 : longitude
                ))
                target += resampleDistance
            }
            traversed += length
        }
        if let end = geometry.last, result.last != end { result.append(end) }
        return result
    }
}

/// Independent of wall time: a 4x replay still reports the configured ground
/// speed and advances timestamps by simulated travel time, not 0.25 seconds.
struct DebugDriveSpeedStamp {
    let metersPerSecond: Double
    private var previous: UserLocation?

    init(metersPerSecond: Double) { self.metersPerSecond = metersPerSecond }

    mutating func stamp(_ location: UserLocation) -> UserLocation? {
        var stamped = location
        if let previous {
            let distance = RouteSignals.distance(previous.coordinates, location.coordinates)
            guard distance > 0.01 else { return nil }
            stamped.timestamp = previous.timestamp.addingTimeInterval(distance / metersPerSecond)
        }
        stamped.speed = Speed(value: metersPerSecond, accuracy: 0)
        // The upstream simulator derives course from this point toward its
        // next point; retaining it describes the direction of travel ahead.
        previous = stamped
        return stamped
    }
}

@MainActor
final class DebugDriveLocationProvider: @preconcurrency LocationProviding, LocationManagingDelegate {
    weak var delegate: LocationManagingDelegate?
    private var provider: SimulatedLocationProvider
    private var stamp: DebugDriveSpeedStamp
    private weak var locationManager: LocationManager?
    private var sourceToken: UUID?
    private var updating = false
    private let settings: DebugDriveSimulationSettings
    private(set) var lastLocation: UserLocation?
    var lastHeading: Heading? { provider.lastHeading }
    var authorizationStatus: CLAuthorizationStatus { provider.authorizationStatus }

    init(route: Route, settings: DebugDriveSimulationSettings, locationManager: LocationManager? = nil) throws {
        provider = SimulatedLocationProvider()
        self.settings = settings
        self.locationManager = locationManager
        stamp = DebugDriveSpeedStamp(metersPerSecond: settings.metersPerSecond)
        var sampledRoute = route
        sampledRoute.geometry = settings.sampled(route.geometry)
        provider.warpFactor = settings.warpFactor
        try provider.setSimulatedRoute(sampledRoute, resampleDistance: .greatestFiniteMagnitude)
        if let location = provider.lastLocation { lastLocation = stamp.stamp(location) }
        provider.delegate = self
    }

    func startUpdating() {
        if updating { stopUpdating() }
        updating = true
        provider.delegate = self
        sourceToken = locationManager?.beginSimulatedSource()
        if let lastLocation {
            publishToSharedLocation(lastLocation)
            delegate?.locationManager(self, didUpdateLocations: [lastLocation])
        }
        provider.startUpdating()
    }

    func stopUpdating() {
        updating = false
        provider.stopUpdating()
        provider.delegate = nil
        if let sourceToken { locationManager?.endSimulatedSource(sourceToken) }
        sourceToken = nil
    }

    func replaceRoute(_ route: Route) throws {
        stopUpdating()
        provider.delegate = nil
        provider = SimulatedLocationProvider()
        provider.warpFactor = settings.warpFactor
        stamp = DebugDriveSpeedStamp(metersPerSecond: settings.metersPerSecond)
        var sampledRoute = route
        sampledRoute.geometry = settings.sampled(route.geometry)
        try provider.setSimulatedRoute(sampledRoute, resampleDistance: .greatestFiniteMagnitude)
        lastLocation = provider.lastLocation.flatMap { stamp.stamp($0) }
        provider.delegate = self
    }

    private func publishToSharedLocation(_ location: UserLocation) {
        guard let sourceToken else { return }
        let fix = CLLocation(coordinate: location.coordinates.clLocationCoordinate2D, altitude: 0,
                             horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: -1,
                             course: location.courseOverGround.map { Double($0.degrees) } ?? -1,
                             speed: location.speed?.value ?? -1, timestamp: location.timestamp)
        locationManager?.ingestSimulated(fix, token: sourceToken)
    }

    nonisolated func locationManager(_ manager: LocationProviding, didUpdateLocations locations: [UserLocation]) {
        let sourceID = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in self?.receive(locations, from: sourceID) }
    }

    private func receive(_ locations: [UserLocation], from sourceID: ObjectIdentifier) {
        guard updating, sourceID == ObjectIdentifier(provider) else { return }
        let stamped = locations.compactMap { stamp.stamp($0) }
        guard let latest = stamped.last else { return }
        lastLocation = latest
        publishToSharedLocation(latest)
        delegate?.locationManager(self, didUpdateLocations: stamped)
    }

    nonisolated func locationManager(_ manager: LocationProviding, didUpdateHeading heading: Heading) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didUpdateHeading: heading)
        }
    }

    nonisolated func locationManager(_ manager: LocationProviding, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didFailWithError: error)
        }
    }
}
#endif
