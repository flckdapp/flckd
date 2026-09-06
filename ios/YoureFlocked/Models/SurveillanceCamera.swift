import Foundation
import CoreLocation
import MapKit

// MARK: - OSM Surveillance Camera

/// A surveillance camera parsed from OpenStreetMap data via the Overpass API.
/// Mirrors the OSM tagging schema: man_made=surveillance, surveillance:type=ALPR, etc.
struct SurveillanceCamera: Identifiable, Codable, Hashable {
    let osmID: Int64
    let latitude: Double
    let longitude: Double
    let tags: [String: String]

    var id: Int64 { osmID }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: - Derived Properties from OSM Tags

    var surveillanceType: SurveillanceType {
        guard let raw = tags["surveillance:type"] else { return .unknown }
        return SurveillanceType(rawValue: raw) ?? .unknown
    }

    var isALPR: Bool {
        surveillanceType == .alpr
    }

    var manufacturer: String? {
        tags["manufacturer"]
    }

    var operatorName: String? {
        tags["operator"]
    }

    var direction: Double? { directions.first?.center }

    var directions: [DirectionEntry] {
        guard let raw = tags["direction"] ?? tags["camera:direction"] else { return [] }
        return raw.split(separator: ";").compactMap { segment -> DirectionEntry? in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if let value = Double(trimmed) {
                return DirectionEntry(center: value, halfAngle: Self.defaultHalfAngle)
            }
            let parts = trimmed.split(separator: "-")
            if parts.count == 2,
               let start = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let end = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                var span = end - start
                if span < 0 { span += 360 }
                let center = (start + span / 2).truncatingRemainder(dividingBy: 360)
                return DirectionEntry(center: center, halfAngle: span / 2)
            }
            return nil
        }
    }

    struct DirectionEntry {
        let center: Double
        let halfAngle: Double
    }

    var cameraType: String? {
        tags["camera:type"]
    }

    var cameraMount: String? {
        tags["camera:mount"]
    }

    var surveillanceZone: String? {
        tags["surveillance:zone"]
    }

    var displayName: String {
        if let mfr = manufacturer {
            return "\(mfr) \(surveillanceType.displayName)"
        }
        return surveillanceType.displayName
    }

    var summary: String {
        var parts: [String] = [surveillanceType.displayName]
        if let mfr = manufacturer { parts.append("by \(mfr)") }
        if let op = operatorName { parts.append("operated by \(op)") }
        if let zone = surveillanceZone { parts.append("monitoring \(zone)") }
        return parts.joined(separator: " ")
    }

    // MARK: - Geometry

    /// Compass bearing (0–360°) from a coordinate to this camera.
    func bearing(from userCoordinate: CLLocationCoordinate2D) -> Double {
        Self.bearing(from: userCoordinate, to: coordinate)
    }

    /// Compass bearing (0–360°, clockwise from north) between two coordinates.
    static func bearing(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
        let lat1 = origin.latitude * .pi / 180
        let lat2 = destination.latitude * .pi / 180
        let dLon = (destination.longitude - origin.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)

        return (radians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Field of View Detection

    static let defaultHalfAngle: Double = 35

    func isInFieldOfView(from userCoordinate: CLLocationCoordinate2D) -> Bool {
        let dirs = directions
        guard !dirs.isEmpty else { return true }

        let bearing = Self.bearing(from: coordinate, to: userCoordinate)

        return dirs.contains { entry in
            var delta = bearing - entry.center
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            return abs(delta) <= entry.halfAngle
        }
    }
}

// MARK: - Surveillance Type Enum

enum SurveillanceType: String, Codable, CaseIterable {
    case alpr = "ALPR"
    case camera = "camera"
    case guard_ = "guard"
    case gunshotDetector = "gunshot_detector"
    case speedCamera = "speed_camera"
    case unknown

    var displayName: String {
        switch self {
        case .alpr: return "License Plate Reader"
        case .camera: return "Surveillance Camera"
        case .guard_: return "Security Guard"
        case .gunshotDetector: return "Gunshot Detector"
        case .speedCamera: return "Speed Camera"
        case .unknown: return "Unknown Device"
        }
    }

    /// Short label for compact UI (banner, map annotations)
    var shortLabel: String {
        switch self {
        case .alpr: return "ALPR"
        case .camera: return "Camera"
        case .guard_: return "Guard"
        case .gunshotDetector: return "Gunshot"
        case .speedCamera: return "Speed"
        case .unknown: return "Unknown"
        }
    }

    var iconName: String {
        switch self {
        case .alpr: return "car.rear.and.tire.marks"
        case .camera: return "video.fill"
        case .guard_: return "person.badge.shield.checkmark.fill"
        case .gunshotDetector: return "waveform.badge.exclamationmark"
        case .speedCamera: return "speedometer"
        case .unknown: return "questionmark.circle"
        }
    }

    var tintColor: String {
        switch self {
        case .alpr: return "red"
        case .camera: return "orange"
        case .guard_: return "blue"
        case .gunshotDetector: return "purple"
        case .speedCamera: return "yellow"
        case .unknown: return "gray"
        }
    }
}

// MARK: - Camera Profile (for adding new cameras to OSM)

/// Predefined tag sets for common camera types, mirroring DeFlock's profile system.
struct CameraProfile: Identifiable, Codable {
    let id: String
    let name: String
    let tags: [String: String]
    let requiresDirection: Bool
    let fieldOfView: Double? // degrees

    static let defaults: [CameraProfile] = [
        CameraProfile(
            id: "generic-alpr",
            name: "Generic ALPR",
            tags: [
                "man_made": "surveillance",
                "surveillance:type": "ALPR",
            ],
            requiresDirection: true,
            fieldOfView: nil
        ),
        CameraProfile(
            id: "flock-safety",
            name: "Flock Safety",
            tags: [
                "man_made": "surveillance",
                "surveillance": "public",
                "surveillance:type": "ALPR",
                "surveillance:zone": "traffic",
                "camera:type": "fixed",
                "manufacturer": "Flock Safety",
            ],
            requiresDirection: true,
            fieldOfView: nil
        ),
        CameraProfile(
            id: "motorola-vigilant",
            name: "Motorola / Vigilant",
            tags: [
                "man_made": "surveillance",
                "surveillance": "public",
                "surveillance:type": "ALPR",
                "surveillance:zone": "traffic",
                "camera:type": "fixed",
                "manufacturer": "Motorola Solutions",
            ],
            requiresDirection: true,
            fieldOfView: nil
        ),
        CameraProfile(
            id: "genetec",
            name: "Genetec",
            tags: [
                "man_made": "surveillance",
                "surveillance": "public",
                "surveillance:type": "ALPR",
                "surveillance:zone": "traffic",
                "camera:type": "fixed",
                "manufacturer": "Genetec",
            ],
            requiresDirection: true,
            fieldOfView: nil
        ),
        CameraProfile(
            id: "generic-camera",
            name: "Generic Camera",
            tags: [
                "man_made": "surveillance",
                "surveillance:type": "camera",
            ],
            requiresDirection: true,
            fieldOfView: nil
        ),
        CameraProfile(
            id: "speed-camera",
            name: "Speed Camera",
            tags: [
                "highway": "speed_camera",
            ],
            requiresDirection: true,
            fieldOfView: nil
        ),
    ]
}
