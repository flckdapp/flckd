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
    private let provider: SimulatedLocationProvider
    private var stamp: DebugDriveSpeedStamp
    private(set) var lastLocation: UserLocation?
    var lastHeading: Heading? { provider.lastHeading }
    var authorizationStatus: CLAuthorizationStatus { provider.authorizationStatus }

    init(route: Route, settings: DebugDriveSimulationSettings) throws {
        provider = SimulatedLocationProvider()
        stamp = DebugDriveSpeedStamp(metersPerSecond: settings.metersPerSecond)
        var sampledRoute = route
        sampledRoute.geometry = settings.sampled(route.geometry)
        provider.warpFactor = settings.warpFactor
        try provider.setSimulatedRoute(sampledRoute, resampleDistance: .greatestFiniteMagnitude)
        if let location = provider.lastLocation { lastLocation = stamp.stamp(location) }
        provider.delegate = self
    }

    func startUpdating() {
        if let lastLocation { delegate?.locationManager(self, didUpdateLocations: [lastLocation]) }
        provider.startUpdating()
    }

    func stopUpdating() { provider.stopUpdating() }

    nonisolated func locationManager(_ manager: LocationProviding, didUpdateLocations locations: [UserLocation]) {
        Task { @MainActor [weak self] in self?.receive(locations) }
    }

    private func receive(_ locations: [UserLocation]) {
        let stamped = locations.compactMap { stamp.stamp($0) }
        guard let latest = stamped.last else { return }
        lastLocation = latest
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
