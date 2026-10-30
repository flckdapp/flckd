import Foundation

// MARK: - Overpass API JSON Response Models

/// Root response from the Overpass API.
/// Endpoint: https://overpass-api.de/api/interpreter
struct OverpassResponse: Codable {
    let version: Double
    let generator: String?
    let osm3s: OSM3S?
    let elements: [OSMElement]
}

struct OSM3S: Codable {
    let timestampOsmBase: String?
    let copyright: String?

    enum CodingKeys: String, CodingKey {
        case timestampOsmBase = "timestamp_osm_base"
        case copyright
    }
}

/// A single OSM element (node, way, or relation) from the Overpass API.
struct OSMElement: Codable, Identifiable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let tags: [String: String]?

    /// For ways/relations using `out center;`, lat/lon come from the center field
    let center: ElementCenter?

    struct ElementCenter: Codable {
        let lat: Double
        let lon: Double
    }

    /// Direct lat, falling back to the center field.
    var resolvedLat: Double? { lat ?? center?.lat }
    /// Direct lon, falling back to the center field.
    var resolvedLon: Double? { lon ?? center?.lon }

    /// Convert to our domain model. Returns nil if coordinates are missing.
    func toSurveillanceCamera() -> SurveillanceCamera? {
        guard let latitude = resolvedLat, let longitude = resolvedLon else {
            return nil
        }

        var cameraTags = tags ?? [:]

        // Speed cameras have their own tag schemes: highway=speed_camera on a
        // node, or a type=enforcement relation (enforcement=maxspeed, and
        // occasionally that key on a bare node). None carry surveillance:type.
        let isSpeedCamera = cameraTags["highway"] == "speed_camera"
            || cameraTags["type"] == "enforcement"
            || cameraTags["enforcement"] != nil
        if isSpeedCamera && cameraTags["surveillance:type"] == nil {
            cameraTags["surveillance:type"] = SurveillanceType.speedCamera.rawValue
        }

        // Node and relation IDs are separate number spaces in OSM but share
        // one `osmID` here. Relations are stored negated so a relation can't
        // overwrite the node with the same number.
        let osmID = type == "relation" ? -id : id

        return SurveillanceCamera(
            osmID: osmID,
            latitude: latitude,
            longitude: longitude,
            tags: cameraTags
        )
    }
}
