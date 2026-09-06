import Foundation
import SwiftData
import CoreLocation

/// SwiftData-persisted camera for offline access and proximity monitoring.
/// Synced from Overpass API responses.
@Model
final class CachedCamera {
    @Attribute(.unique) var osmID: Int64
    var latitude: Double
    var longitude: Double
    var surveillanceType: String
    var manufacturer: String?
    var operatorName: String?
    var direction: Double?
    var cameraMount: String?
    var surveillanceZone: String?
    var tagsJSON: Data? // full tag dict serialized

    var lastFetched: Date
    var isUserSubmitted: Bool
    var isPendingUpload: Bool
    var userNotes: String?
    var profileID: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(from camera: SurveillanceCamera) {
        self.osmID = camera.osmID
        self.latitude = camera.latitude
        self.longitude = camera.longitude
        self.surveillanceType = camera.surveillanceType.rawValue
        self.manufacturer = camera.manufacturer
        self.operatorName = camera.operatorName
        self.direction = camera.direction
        self.cameraMount = camera.cameraMount
        self.surveillanceZone = camera.surveillanceZone
        self.tagsJSON = try? JSONEncoder().encode(camera.tags)
        self.lastFetched = Date()
        self.isUserSubmitted = false
        self.isPendingUpload = false
        self.userNotes = nil
        self.profileID = nil
    }

    init(
        osmID: Int64,
        latitude: Double,
        longitude: Double,
        surveillanceType: String,
        manufacturer: String? = nil,
        operatorName: String? = nil,
        direction: Double? = nil,
        cameraMount: String? = nil,
        surveillanceZone: String? = nil
    ) {
        self.osmID = osmID
        self.latitude = latitude
        self.longitude = longitude
        self.surveillanceType = surveillanceType
        self.manufacturer = manufacturer
        self.operatorName = operatorName
        self.direction = direction
        self.cameraMount = cameraMount
        self.surveillanceZone = surveillanceZone
        self.lastFetched = Date()
        self.isUserSubmitted = false
        self.isPendingUpload = false
        self.userNotes = nil
        self.profileID = nil
    }

    init(
        pending profile: CameraProfile,
        latitude: Double,
        longitude: Double,
        direction: Double?,
        notes: String?
    ) {
        self.osmID = -Int64(Date().timeIntervalSince1970 * 1000)
        self.latitude = latitude
        self.longitude = longitude
        self.surveillanceType = profile.tags["surveillance:type"] ?? "camera"
        self.manufacturer = profile.tags["manufacturer"]
        self.operatorName = profile.tags["operator"]
        self.direction = direction
        self.cameraMount = profile.tags["camera:mount"]
        self.surveillanceZone = profile.tags["surveillance:zone"]
        self.tagsJSON = try? JSONEncoder().encode(profile.tags)
        self.lastFetched = Date()
        self.isUserSubmitted = true
        self.isPendingUpload = true
        self.userNotes = notes
        self.profileID = profile.id
    }

    /// Convert back to a SurveillanceCamera value type for use in views
    func toSurveillanceCamera() -> SurveillanceCamera {
        var tags: [String: String] = [:]
        if let data = tagsJSON {
            tags = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        // The typed columns win over tagsJSON, which may be stale.
        tags["surveillance:type"] = surveillanceType
        if let mfr = manufacturer { tags["manufacturer"] = mfr }
        if let op = operatorName { tags["operator"] = op }

        return SurveillanceCamera(
            osmID: osmID,
            latitude: latitude,
            longitude: longitude,
            tags: tags
        )
    }
}
