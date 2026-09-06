import Foundation
import CoreLocation

// MARK: - DeFlock CDN Bulk Camera Service

/// Fetches bulk ALPR camera data from DeFlock's public CDN.
///
/// DeFlock publishes an hourly snapshot of all ALPR cameras worldwide
/// (derived from OpenStreetMap) as 20-degree tiles:
///   - Index:  https://cdn.deflock.me/regions/index.json
///     -> { expiration_utc, tile_url, tile_size_degrees, regions[] }
///   - Tile:   https://cdn.deflock.me/regions/{lat}/{lon}.json?v=<epoch>
///     -> bare array of { id, lat, lon, tags }
///     where {lat}/{lon} = floor(coord / 20) * 20.
///
/// This is the same data source DeFlock's own website uses, so it stays
/// available when the public Overpass instances are overloaded. Tiles are
/// cached on disk and reused until the index's published expiration, which
/// covers pans and offline warm starts. The CDN contains ALPRs only; speed
/// cameras still come from Overpass.
///
/// Data licence: OpenStreetMap contributors, ODbL. Attribution is shown in
/// Settings -> Camera Data.
actor DeFlockCDNService {

    // MARK: - Configuration

    private static let indexURL = URL(string: "https://cdn.deflock.me/regions/index.json")!
    private static let userAgent = "FLCKD/1.0 (iOS; +https://flckd.app)"
    private static let requestTimeout: TimeInterval = 30

    private let session: URLSession
    private let cacheDirectory: URL

    // MARK: - Types

    struct CDNIndex: Codable {
        let expirationUTC: TimeInterval
        let tileURL: String
        let tileSizeDegrees: Double
        let regions: [String]

        enum CodingKeys: String, CodingKey {
            case expirationUTC = "expiration_utc"
            case tileURL = "tile_url"
            case tileSizeDegrees = "tile_size_degrees"
            case regions
        }

        var expirationDate: Date { Date(timeIntervalSince1970: expirationUTC) }

        /// The `?v=<epoch>` version baked into the tile URL template.
        /// Used as the disk-cache key so a new publish invalidates old tiles.
        var version: String {
            tileURL.components(separatedBy: "?v=").last ?? "0"
        }
    }

    struct CDNNode: Codable {
        let id: Int64
        let lat: Double
        let lon: Double
        let tags: [String: String]?
    }

    /// Status snapshot for the Settings screen.
    struct Status: Sendable {
        var lastTileDate: Date?
        var cachedTileCount: Int
        var cachedBytes: Int64
        var lastFetchWasFromCache: Bool
    }

    enum CDNError: LocalizedError {
        case indexUnavailable
        case tileUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .indexUnavailable:
                return "DeFlock CDN index unavailable"
            case .tileUnavailable(let key):
                return "DeFlock CDN tile \(key) unavailable"
            }
        }
    }

    // MARK: - State

    private var cachedIndex: CDNIndex?
    private var lastTileDate: Date?
    private var lastFetchWasFromCache = false

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout * 4
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: config)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = caches.appendingPathComponent("DeFlockCDN", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Fetch all ALPR cameras within the given bounding box from the CDN.
    ///
    /// Downloads (or reuses from disk) every 20-degree tile that intersects
    /// the box, then filters nodes to the box. If the network is down but a
    /// stale tile exists on disk, the stale tile is used.
    func fetchALPRCameras(in bounds: BoundingBox) async throws -> [SurveillanceCamera] {
        let index = try await fetchIndex()
        let size = index.tileSizeDegrees > 0 ? index.tileSizeDegrees : 20

        var cameras: [SurveillanceCamera] = []
        for key in tileKeys(for: bounds, tileSize: size) {
            // Skip tiles the CDN doesn't publish (no cameras there).
            guard index.regions.contains(key) else { continue }
            let nodes = try await fetchTile(key: key, index: index)
            for node in nodes {
                guard node.lat >= bounds.south, node.lat <= bounds.north,
                      node.lon >= bounds.west, node.lon <= bounds.east else { continue }
                cameras.append(Self.toSurveillanceCamera(node))
            }
        }
        return cameras
    }

    /// Current cache/freshness info for the Settings screen.
    func status() -> Status {
        var count = 0
        var bytes: Int64 = 0
        if let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files where file.pathExtension == "json" {
                count += 1
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return Status(
            lastTileDate: lastTileDate,
            cachedTileCount: count,
            cachedBytes: bytes,
            lastFetchWasFromCache: lastFetchWasFromCache
        )
    }

    /// Delete all cached tiles (Settings -> Clear).
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        cachedIndex = nil
        lastTileDate = nil
    }

    // MARK: - Index

    private func fetchIndex() async throws -> CDNIndex {
        // Reuse the in-memory index until its published expiration.
        if let index = cachedIndex, index.expirationDate > Date() {
            return index
        }
        var request = URLRequest(url: Self.indexURL)
        request.cachePolicy = .reloadRevalidatingCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw CDNError.indexUnavailable
            }
            let index = try JSONDecoder().decode(CDNIndex.self, from: data)
            cachedIndex = index
            try? data.write(to: cacheDirectory.appendingPathComponent("index.cached.json"))
            return index
        } catch {
            // Network down: fall back to the last index we saw on disk,
            // even if expired: stale cameras beat no cameras.
            let cachedFile = cacheDirectory.appendingPathComponent("index.cached.json")
            if let data = try? Data(contentsOf: cachedFile),
               let index = try? JSONDecoder().decode(CDNIndex.self, from: data) {
                cachedIndex = index
                return index
            }
            throw CDNError.indexUnavailable
        }
    }

    // MARK: - Tiles

    /// All tile keys ("lat/lon") intersecting the bounding box.
    private func tileKeys(for bounds: BoundingBox, tileSize: Double) -> [String] {
        func floorTile(_ value: Double) -> Int {
            Int((value / tileSize).rounded(.down)) * Int(tileSize)
        }
        var keys: [String] = []
        var lat = floorTile(bounds.south)
        while Double(lat) <= bounds.north {
            var lon = floorTile(bounds.west)
            while Double(lon) <= bounds.east {
                keys.append("\(lat)/\(lon)")
                lon += Int(tileSize)
            }
            lat += Int(tileSize)
        }
        return keys
    }

    private func fetchTile(key: String, index: CDNIndex) async throws -> [CDNNode] {
        let fileName = key.replacingOccurrences(of: "/", with: "_")
        let cachedFile = cacheDirectory.appendingPathComponent("\(fileName).json")
        let versionFile = cacheDirectory.appendingPathComponent("\(fileName).version")

        // Fresh disk cache: same published version -> no network at all.
        if let versionData = try? String(contentsOf: versionFile, encoding: .utf8),
           versionData == index.version,
           let data = try? Data(contentsOf: cachedFile),
           let nodes = try? JSONDecoder().decode([CDNNode].self, from: data) {
            lastFetchWasFromCache = true
            lastTileDate = (try? FileManager.default.attributesOfItem(
                atPath: cachedFile.path)[.modificationDate] as? Date) ?? lastTileDate
            return nodes
        }

        let parts = key.split(separator: "/")
        let urlString = index.tileURL
            .replacingOccurrences(of: "{lat}", with: String(parts[0]))
            .replacingOccurrences(of: "{lon}", with: String(parts[1]))
        guard let url = URL(string: urlString) else {
            throw CDNError.tileUnavailable(key)
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw CDNError.tileUnavailable(key)
            }
            let nodes = try JSONDecoder().decode([CDNNode].self, from: data)
            try? data.write(to: cachedFile)
            try? index.version.write(to: versionFile, atomically: true, encoding: .utf8)
            lastFetchWasFromCache = false
            lastTileDate = Date()
            return nodes
        } catch {
            // Network down: serve the stale tile if we have one.
            if let data = try? Data(contentsOf: cachedFile),
               let nodes = try? JSONDecoder().decode([CDNNode].self, from: data) {
                lastFetchWasFromCache = true
                return nodes
            }
            throw error
        }
    }

    // MARK: - Mapping

    /// Convert a CDN node into the app's camera model.
    ///
    /// The CDN publishes ALPRs only and omits the OSM classification tags,
    /// so `man_made=surveillance` / `surveillance:type=ALPR` are injected
    /// when missing, since the rest of the app keys off `isALPR`.
    private static func toSurveillanceCamera(_ node: CDNNode) -> SurveillanceCamera {
        var tags = node.tags ?? [:]
        if tags["man_made"] == nil { tags["man_made"] = "surveillance" }
        if tags["surveillance:type"] == nil { tags["surveillance:type"] = "ALPR" }
        return SurveillanceCamera(
            osmID: node.id,
            latitude: node.lat,
            longitude: node.lon,
            tags: tags
        )
    }
}
