import Foundation
import CoreLocation

// MARK: - Overpass API Service

/// Fetches surveillance camera data from OpenStreetMap via the Overpass API.
///
/// Uses the same query patterns as DeFlock:
///   - `man_made=surveillance` + `surveillance:type=ALPR` for ALPR cameras
///   - `highway=speed_camera` for speed enforcement cameras
///   - Bbox-scoped queries for mobile efficiency
///
/// Reference: https://wiki.openstreetmap.org/wiki/Overpass_API
/// Reference: https://github.com/FoggedLens/deflock-app/blob/main/lib/services/overpass_service.dart
actor OverpassService {

    // MARK: - Configuration

    /// Primary Overpass API endpoint: DeFlock's own Overpass instance.
    ///
    /// This is the default endpoint in the official deflock-app
    /// (lib/services/overpass_service.dart). It is operated specifically for
    /// camera queries, so it stays up when the public mirrors are degraded.
    private static let primaryEndpoint = "https://overpass.deflock.org/api/interpreter"

    /// Fallback endpoints, tried in order when the primary fails. The Kumi
    /// Systems and private.coffee instances are independently operated
    /// mirrors, so at least two separate infrastructures are tried.
    private static let fallbackEndpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]

    private static let userAgent = "FLCKD/1.0 (iOS; +https://flckd.app)"
    private static let queryTimeout: TimeInterval = 45 // DeFlock uses 45s
    private static let maxRetries = 3

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.queryTimeout
        config.timeoutIntervalForResource = Self.queryTimeout * 2
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch all surveillance cameras within the given bounding box.
    ///
    /// Queries for ALPR cameras, generic surveillance cameras, and speed cameras
    /// in a single Overpass request. Results are cached locally via CameraStore.
    func fetchCameras(in bounds: BoundingBox) async throws -> [SurveillanceCamera] {
        let query = buildQuery(bounds: bounds)
        let data = try await executeQuery(query)
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements.compactMap { $0.toSurveillanceCamera() }
    }

    /// Fetch only speed cameras within the given bounding box.
    ///
    /// Used alongside the DeFlock CDN bulk source: the CDN covers ALPRs,
    /// Overpass fills in speed cameras.
    func fetchSpeedCameras(in bounds: BoundingBox) async throws -> [SurveillanceCamera] {
        let query = """
        [out:json][timeout:25];
        (
          node["highway"="speed_camera"](\(bounds.overpassBBox));
        );
        out body;
        """
        let data = try await executeQuery(query)
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements.compactMap { $0.toSurveillanceCamera() }
    }

    /// Fetch only ALPR cameras within the given bounding box.
    func fetchALPRCameras(in bounds: BoundingBox) async throws -> [SurveillanceCamera] {
        let query = buildALPRQuery(bounds: bounds)
        let data = try await executeQuery(query)
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements.compactMap { $0.toSurveillanceCamera() }
    }

    // MARK: - Query Building

    /// Combined query for all surveillance types, matching DeFlock's query.
    private func buildQuery(bounds: BoundingBox) -> String {
        """
        [out:json][timeout:25];
        (
          node["man_made"="surveillance"]["surveillance:type"~"camera|ALPR"](\(bounds.overpassBBox));
          node["highway"="speed_camera"](\(bounds.overpassBBox));
        );
        out body;
        """
    }

    /// ALPR-only query.
    private func buildALPRQuery(bounds: BoundingBox) -> String {
        """
        [out:json][timeout:25];
        (
          node["man_made"="surveillance"]["surveillance:type"="ALPR"](\(bounds.overpassBBox));
        );
        out body;
        """
    }

    // MARK: - Network Execution with Retry

    private func executeQuery(_ query: String, attempt: Int = 0) async throws -> Data {
        let endpoints = [Self.primaryEndpoint] + Self.fallbackEndpoints
        let endpointIndex = min(attempt, endpoints.count - 1)
        let endpoint = endpoints[endpointIndex]

        guard var components = URLComponents(string: endpoint) else {
            throw OverpassError.invalidEndpoint
        }
        components.queryItems = [URLQueryItem(name: "data", value: query)]

        guard let url = components.url else {
            throw OverpassError.invalidQuery
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OverpassError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                return data
            case 429:
                // Rate limited: back off and retry.
                if attempt < Self.maxRetries {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(for: .seconds(delay))
                    return try await executeQuery(query, attempt: attempt + 1)
                }
                throw OverpassError.rateLimited
            case 400:
                throw OverpassError.badQuery(String(data: data, encoding: .utf8) ?? "Unknown error")
            default:
                if attempt < Self.maxRetries {
                    return try await executeQuery(query, attempt: attempt + 1)
                }
                throw OverpassError.serverError(httpResponse.statusCode)
            }
        } catch let error as OverpassError {
            throw error
        } catch {
            // Network error: back off and move to the next endpoint.
            if attempt < Self.maxRetries {
                let delay = pow(2.0, Double(attempt))
                try await Task.sleep(for: .seconds(delay))
                return try await executeQuery(query, attempt: attempt + 1)
            }
            throw OverpassError.networkError(error)
        }
    }
}

// MARK: - Supporting Types

struct BoundingBox: Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    /// Overpass API bbox format: south,west,north,east
    var overpassBBox: String {
        "\(south),\(west),\(north),\(east)"
    }

    /// Whether a coordinate falls inside this box.
    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        coord.latitude >= south && coord.latitude <= north
            && coord.longitude >= west && coord.longitude <= east
    }

    /// Whether this box fully contains another box.
    func contains(_ other: BoundingBox) -> Bool {
        other.south >= south && other.north <= north
            && other.west >= west && other.east <= east
    }

    /// Create a bounding box centered on a coordinate with a radius in kilometers.
    static func around(center: CLLocationCoordinate2D, radiusKm: Double) -> BoundingBox {
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / (111.0 * cos(center.latitude * .pi / 180))
        return BoundingBox(
            south: center.latitude - latDelta,
            west: center.longitude - lonDelta,
            north: center.latitude + latDelta,
            east: center.longitude + lonDelta
        )
    }
}

enum OverpassError: LocalizedError {
    case invalidEndpoint
    case invalidQuery
    case invalidResponse
    case rateLimited
    case badQuery(String)
    case serverError(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid Overpass API endpoint"
        case .invalidQuery: return "Could not construct query URL"
        case .invalidResponse: return "Invalid response from Overpass API"
        case .rateLimited: return "Overpass API rate limit exceeded. Try again in a moment."
        case .badQuery(let msg): return "Overpass query error: \(msg)"
        case .serverError(let code): return "Overpass server error (HTTP \(code))"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}
