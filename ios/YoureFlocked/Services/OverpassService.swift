import Foundation
import CoreLocation

// MARK: - Overpass API Service

/// Fetches speed-camera data (and, when the DeFlock CDN is down, all camera
/// data) from OpenStreetMap via the Overpass API, one whole-degree grid cell
/// at a time.
///
/// The only geometry that ever reaches the wire is a `GridCell`: four
/// integers that are identical for every phone inside the same 1° × 1° cell.
/// Nothing in the request is computed from a position, so nothing in it can
/// be inverted back to one. Each cell is cached on disk and is not requested
/// again until the cache expires.
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

    /// Fallback endpoints, tried in order when the primary fails.
    private static let fallbackEndpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]

    /// How many distinct servers one cell may be sent to during a single
    /// fetch. Every server that receives the request learns which cell the
    /// phone is in, so a failure should not broadcast it to all of them.
    static let maxEndpointsPerFetch = 2

    /// Total attempts per fetch, across at most `maxEndpointsPerFetch` hosts.
    private static let maxAttempts = 3

    /// How long a cached cell is served without asking the network again.
    /// Speed cameras are small, static data; a day is plenty.
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private static let userAgent = "FLCKD/1.0 (iOS; +https://flckd.app)"
    private static let queryTimeout: TimeInterval = 45 // DeFlock uses 45s

    /// What a cell query asks for.
    enum Kind: String, Sendable {
        /// Speed cameras only. The normal case: ALPRs come from the CDN.
        case speed
        /// Every camera type. Used only when the CDN is unavailable.
        case all
    }

    private let session: URLSession
    private let cacheDirectory: URL

    /// - Parameters:
    ///   - session: Injected by tests to observe requests. Defaults to a
    ///     session with the app's User-Agent and timeouts.
    ///   - cacheDirectory: Where cell files live. Defaults to Caches.
    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.queryTimeout
            config.timeoutIntervalForResource = Self.queryTimeout * 2
            config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
            self.session = URLSession(configuration: config)
        }

        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.cacheDirectory = caches.appendingPathComponent("OverpassCells", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Speed cameras in one grid cell, from disk when fresh.
    func speedCameras(in cell: GridCell) async throws -> [SurveillanceCamera] {
        try await cameras(in: cell, kind: .speed)
    }

    /// Every camera type in one grid cell, from disk when fresh. Only for
    /// when the DeFlock CDN is unavailable; the response can be large.
    func allCameras(in cell: GridCell) async throws -> [SurveillanceCamera] {
        try await cameras(in: cell, kind: .all)
    }

    /// Delete every cached cell (Settings -> Clear).
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Query Building

    /// The Overpass QL sent for a cell. Internal so tests can check that the
    /// bbox is four integers and nothing else.
    ///
    /// Speed cameras are mapped two ways in OSM: `highway=speed_camera` nodes
    /// and `type=enforcement` relations (with a handful of bare
    /// `enforcement=maxspeed` nodes). Several hundred US cameras exist only
    /// as relations, so both schemes are read. `out center` gives relations
    /// a representative point.
    static func query(for cell: GridCell, kind: Kind) -> String {
        let bbox = cell.overpassBBox
        let speed = """
          node["highway"="speed_camera"](\(bbox));
          node["enforcement"="maxspeed"](\(bbox));
          relation["type"="enforcement"](\(bbox));
        """
        switch kind {
        case .speed:
            return """
            [out:json][timeout:25];
            (
            \(speed)
            );
            out center;
            """
        case .all:
            return """
            [out:json][timeout:60];
            (
              node["man_made"="surveillance"]["surveillance:type"~"camera|ALPR"](\(bbox));
            \(speed)
            );
            out center;
            """
        }
    }

    // MARK: - Cell Cache

    private func cameras(in cell: GridCell, kind: Kind) async throws -> [SurveillanceCamera] {
        let file = cacheFile(for: cell, kind: kind)

        if let cached = readCache(file), cached.age < Self.cacheTTL {
            return cached.cameras
        }

        do {
            let data = try await executeQuery(Self.query(for: cell, kind: kind))
            let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
            let cameras = response.elements.compactMap { $0.toSurveillanceCamera() }
            if let encoded = try? JSONEncoder().encode(cameras) {
                try? encoded.write(to: file, options: .atomic)
            }
            return cameras
        } catch {
            // Network down: a stale cell beats no cell.
            if let cached = readCache(file) {
                return cached.cameras
            }
            throw error
        }
    }

    private func cacheFile(for cell: GridCell, kind: Kind) -> URL {
        cacheDirectory.appendingPathComponent("\(kind.rawValue)_\(cell.key).json")
    }

    private func readCache(_ file: URL) -> (cameras: [SurveillanceCamera], age: TimeInterval)? {
        guard let data = try? Data(contentsOf: file),
              let cameras = try? JSONDecoder().decode([SurveillanceCamera].self, from: data) else {
            return nil
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            ?? .distantPast
        return (cameras, Date().timeIntervalSince(modified))
    }

    // MARK: - Network Execution with Retry

    /// POST, so the query is in the request body rather than in the URL,
    /// where it would land in ordinary web-server access logs.
    private func executeQuery(_ query: String, attempt: Int = 0) async throws -> Data {
        let endpoints = Array(([Self.primaryEndpoint] + Self.fallbackEndpoints).prefix(Self.maxEndpointsPerFetch))
        let endpoint = endpoints[min(attempt, endpoints.count - 1)]

        guard let url = URL(string: endpoint) else {
            throw OverpassError.invalidEndpoint
        }
        guard let body = Self.formBody(for: query) else {
            throw OverpassError.invalidQuery
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let canRetry = attempt + 1 < Self.maxAttempts

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OverpassError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                return data
            case 429:
                // Rate limited: back off and retry.
                if canRetry {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(for: .seconds(delay))
                    return try await executeQuery(query, attempt: attempt + 1)
                }
                throw OverpassError.rateLimited
            case 400:
                throw OverpassError.badQuery(String(data: data, encoding: .utf8) ?? "Unknown error")
            default:
                if canRetry {
                    return try await executeQuery(query, attempt: attempt + 1)
                }
                throw OverpassError.serverError(httpResponse.statusCode)
            }
        } catch let error as OverpassError {
            throw error
        } catch {
            // Network error: back off and move to the next endpoint.
            if canRetry {
                let delay = pow(2.0, Double(attempt))
                try await Task.sleep(for: .seconds(delay))
                return try await executeQuery(query, attempt: attempt + 1)
            }
            throw OverpassError.networkError(error)
        }
    }

    /// `data=<query>` encoded as application/x-www-form-urlencoded.
    static func formBody(for query: String) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return Data("data=\(encoded)".utf8)
    }
}

// MARK: - Supporting Types

/// One cell of a fixed, global, whole-degree grid.
///
/// This is the unit of every Overpass request. The grid is anchored at the
/// equator and prime meridian, never at the user, so the cell a phone asks
/// for depends only on which 1° × 1° box it is in. About 111 km by 85 km at
/// US latitudes.
struct GridCell: Hashable, Sendable, Codable {
    /// South edge, whole degrees.
    let lat: Int
    /// West edge, whole degrees.
    let lon: Int

    init(lat: Int, lon: Int) {
        self.lat = min(max(lat, -90), 89)
        self.lon = min(max(lon, -180), 179)
    }

    /// The cell containing a coordinate.
    init(containing coordinate: CLLocationCoordinate2D) {
        self.init(
            lat: Int(coordinate.latitude.rounded(.down)),
            lon: Int(coordinate.longitude.rounded(.down))
        )
    }

    /// Every cell a box intersects. A box that lies inside one cell yields
    /// just that cell; a box touching an edge yields the neighbour too.
    static func covering(_ bounds: BoundingBox) -> [GridCell] {
        let south = Int(bounds.south.rounded(.down))
        let west = Int(bounds.west.rounded(.down))
        let north = max(Int(bounds.north.rounded(.up)), south + 1)
        let east = max(Int(bounds.east.rounded(.up)), west + 1)
        var cells: [GridCell] = []
        for lat in south..<north {
            for lon in west..<east {
                cells.append(GridCell(lat: lat, lon: lon))
            }
        }
        return cells
    }

    var bounds: BoundingBox {
        BoundingBox(south: Double(lat), west: Double(lon), north: Double(lat + 1), east: Double(lon + 1))
    }

    /// Overpass bbox: south,west,north,east. Four integers.
    var overpassBBox: String {
        "\(lat),\(lon),\(lat + 1),\(lon + 1)"
    }

    /// Filesystem-safe name.
    var key: String {
        "\(lat)_\(lon)"
    }
}

/// A box in degrees. Used on the device to pick grid cells and to filter
/// cached cameras. It is never sent anywhere: there is deliberately no
/// method that formats it for a request.
struct BoundingBox: Sendable, Equatable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    /// Whether a coordinate falls inside this box.
    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        coord.latitude >= south && coord.latitude <= north
            && coord.longitude >= west && coord.longitude <= east
    }

    /// The smallest box containing all of the given boxes.
    static func union(_ boxes: [BoundingBox]) -> BoundingBox? {
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { acc, box in
            BoundingBox(
                south: min(acc.south, box.south),
                west: min(acc.west, box.west),
                north: max(acc.north, box.north),
                east: max(acc.east, box.east)
            )
        }
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
        case .invalidQuery: return "Could not encode the Overpass query"
        case .invalidResponse: return "Invalid response from Overpass API"
        case .rateLimited: return "Overpass API rate limit exceeded. Try again in a moment."
        case .badQuery(let msg): return "Overpass query error: \(msg)"
        case .serverError(let code): return "Overpass server error (HTTP \(code))"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}
