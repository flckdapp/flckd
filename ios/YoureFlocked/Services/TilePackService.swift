import CoreLocation
import CryptoKit
import Foundation

// MARK: - Tile Server Manifest Models

/// Mirrors /v1/manifest.json served by the FLCKD tile service (server/).
struct TileManifest: Codable {
    let schema: Int
    let buildId: String
    let valhallaVersion: String
    let osmDataDate: String?
    let totalBytes: Int64?
    let packs: [TilePack]

    enum CodingKeys: String, CodingKey {
        case schema, packs
        case buildId = "build_id"
        case valhallaVersion = "valhalla_version"
        case osmDataDate = "osm_data_date"
        case totalBytes = "total_bytes"
    }
}

struct TilePack: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let iso3166: String?
    let bytes: Int64
    let sha256: String
    let partBytes: Int64?
    let parts: [TilePackPart]

    enum CodingKeys: String, CodingKey {
        case id, name, bytes, sha256, parts
        case iso3166 = "iso3166_2"
        case partBytes = "part_bytes"
    }
}

struct TilePackPart: Codable, Hashable {
    let index: Int
    let path: String
    let bytes: Int64
    let sha256: String
}

/// Sidecar written next to each installed .tar so the app knows what it has
/// without re-hashing 300 MB on every launch.
struct InstalledRegion: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let buildId: String
    let bytes: Int64
    let sha256: String
    let valhallaVersion: String
    let installedAt: Date
}

// MARK: - Region Store

/// Owns the on-disk layout for downloaded routing regions:
///
///     Application Support/valhalla/regions/<id>.tar    <- mmapped, never unpacked
///     Application Support/valhalla/regions/<id>.json   <- InstalledRegion sidecar
///
/// The directory carries the iCloud backup-exclusion flag: re-downloadable data
/// must not be backed up (iOS Data Storage Guidelines, QA1719).
enum RegionStore {

    /// Tiles are mmapped binary structs; reader and writer must agree exactly.
    /// The embedded engine (valhalla-mobile 0.6.3) is Valhalla 3.6.3.
    static let supportedValhallaVersion = "3.6.3"

    static func regionsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var dir = base.appendingPathComponent("valhalla/regions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        }
        return dir
    }

    static func tarURL(for id: String) -> URL? {
        guard let dir = try? regionsDirectory() else { return nil }
        return dir.appendingPathComponent("\(id).tar")
    }

    static func sidecarURL(for id: String) -> URL? {
        guard let dir = try? regionsDirectory() else { return nil }
        return dir.appendingPathComponent("\(id).json")
    }

    /// All regions with both a tar and a valid sidecar on disk.
    static func installedRegions() -> [InstalledRegion] {
        guard let dir = try? regionsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var regions: [InstalledRegion] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let region = try? decoder.decode(InstalledRegion.self, from: data) else { continue }
            let tar = dir.appendingPathComponent("\(region.id).tar")
            if FileManager.default.fileExists(atPath: tar.path) {
                regions.append(region)
            }
        }
        return regions.sorted { $0.name < $1.name }
    }

    /// The tar the routing engine should load for a route between the given
    /// coordinates: the installed region whose bounds contain every
    /// coordinate. Overlapping state boxes resolve to the smallest (most
    /// specific) region. Falls back to the largest installed region when no
    /// single region contains the whole route.
    static func bestAvailableRegion(containing coordinates: [CLLocationCoordinate2D]) -> URL? {
        let regions = installedRegions()
            .filter { $0.valhallaVersion == supportedValhallaVersion }
        let fits = regions.compactMap { region -> (id: String, area: Double)? in
            guard let bounds = USStateBounds.all.first(where: { $0.id == region.id }),
                  coordinates.allSatisfy({ bounds.contains($0) }) else { return nil }
            return (region.id, bounds.area)
        }
        if let pick = fits.min(by: { $0.area < $1.area }) {
            return tarURL(for: pick.id)
        }
        return bestAvailableRegion()
    }

    /// The fallback tar when no route coordinates are known: with one region
    /// installed this is trivially it; with several we pick the largest.
    static func bestAvailableRegion() -> URL? {
        let regions = installedRegions()
            .filter { $0.valhallaVersion == supportedValhallaVersion }
        guard let pick = regions.max(by: { $0.bytes < $1.bytes }) else { return nil }
        return tarURL(for: pick.id)
    }

    static func delete(_ id: String) throws {
        let fm = FileManager.default
        if let tar = tarURL(for: id), fm.fileExists(atPath: tar.path) {
            try fm.removeItem(at: tar)
        }
        if let sidecar = sidecarURL(for: id), fm.fileExists(atPath: sidecar.path) {
            try fm.removeItem(at: sidecar)
        }
    }
}

// MARK: - Tile Pack Service

enum TilePackError: LocalizedError {
    case invalidServerURL
    case serverError(Int)
    case invalidManifest
    case versionMismatch(server: String)
    case checksumMismatch(String)
    case notATilePack
    case insufficientSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Invalid tile server URL. Check the address in Settings."
        case .serverError(let code):
            return "Tile server error (HTTP \(code))."
        case .invalidManifest:
            return "The tile server returned an unreadable manifest."
        case .versionMismatch(let server):
            return "Server tiles are built with Valhalla \(server); this app requires \(RegionStore.supportedValhallaVersion)."
        case .checksumMismatch(let what):
            return "Download corrupted (\(what) checksum failed). Try again."
        case .notATilePack:
            return "Downloaded file is not a valid tile pack."
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough free space: need \(f.string(fromByteCount: needed)), have \(f.string(fromByteCount: available))."
        }
    }
}

/// Talks to the FLCKD tile server: fetches the manifest, downloads packs part
/// by part, verifies every checksum, and installs into RegionStore.
actor TilePackService {

    static let defaultServerURL = "https://tiles.flckd.app"
    /// Old development defaults; stored values matching these are migrated
    /// to `defaultServerURL` so existing installs pick up the hosted server.
    private static let legacyServerURLs: Set<String> = [
        "http://localhost:8080",
        "http://127.0.0.1:8080",
    ]
    private static let userAgent = "FLCKD/1.0 (iOS; +https://flckd.app)"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: config)
    }

    static func serverBaseURL() -> URL? {
        var raw = UserDefaults.standard.string(forKey: "tileServerURL") ?? defaultServerURL
        if legacyServerURLs.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           !ProcessInfo.processInfo.arguments.contains("-tileServerURL") {
            raw = defaultServerURL
            UserDefaults.standard.set(defaultServerURL, forKey: "tileServerURL")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil else {
            return nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }

    // MARK: Manifest

    func fetchManifest() async throws -> TileManifest {
        guard let base = Self.serverBaseURL() else { throw TilePackError.invalidServerURL }
        let url = base.appendingPathComponent("v1/manifest.json")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw TilePackError.invalidManifest }
        guard http.statusCode == 200 else { throw TilePackError.serverError(http.statusCode) }
        do {
            let manifest = try JSONDecoder().decode(TileManifest.self, from: data)
            guard manifest.valhallaVersion == RegionStore.supportedValhallaVersion else {
                throw TilePackError.versionMismatch(server: manifest.valhallaVersion)
            }
            return manifest
        } catch let error as TilePackError {
            throw error
        } catch {
            throw TilePackError.invalidManifest
        }
    }

    // MARK: Download

    /// Downloads one pack: each part is fetched, its sha256 verified, and the
    /// bytes appended to a temp file while a running hash of the whole tar is
    /// maintained. On success the tar is atomically moved into RegionStore.
    func downloadPack(
        _ pack: TilePack,
        buildId: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let base = Self.serverBaseURL() else { throw TilePackError.invalidServerURL }
        let regionsDir = try RegionStore.regionsDirectory()

        // Free-space check: pack + one part of headroom.
        let values = try regionsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage {
            let needed = pack.bytes + (pack.partBytes ?? 134_217_728)
            if available < needed {
                throw TilePackError.insufficientSpace(needed: needed, available: available)
            }
        }

        let tmpURL = regionsDir.appendingPathComponent("\(pack.id).tar.partial")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        defer { try? handle.close() }

        var wholeHasher = SHA256()
        var written: Int64 = 0
        let total = Double(max(pack.bytes, 1))

        do {
            for part in pack.parts.sorted(by: { $0.index < $1.index }) {
                guard let partURL = URL(string: part.path, relativeTo: base) else {
                    throw TilePackError.invalidServerURL
                }
                let (fileURL, response) = try await session.download(from: partURL.absoluteURL)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw TilePackError.serverError(code)
                }

                // Stream the part into the tar, hashing part and whole as we go.
                var partHasher = SHA256()
                let reader = try FileHandle(forReadingFrom: fileURL)
                defer { try? reader.close() }
                while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    partHasher.update(data: chunk)
                    wholeHasher.update(data: chunk)
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    progress(min(Double(written) / total, 1.0))
                }
                let partDigest = partHasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard partDigest == part.sha256 else {
                    throw TilePackError.checksumMismatch("part \(part.index)")
                }
            }
            try handle.close()

            let wholeDigest = wholeHasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard wholeDigest == pack.sha256 else {
                throw TilePackError.checksumMismatch("pack")
            }
            try Self.verifyFirstTarMemberIsIndex(tmpURL)

            // Install atomically.
            let finalTar = regionsDir.appendingPathComponent("\(pack.id).tar")
            if FileManager.default.fileExists(atPath: finalTar.path) {
                try FileManager.default.removeItem(at: finalTar)
            }
            try FileManager.default.moveItem(at: tmpURL, to: finalTar)

            let sidecar = InstalledRegion(
                id: pack.id,
                name: pack.name,
                buildId: buildId,
                bytes: pack.bytes,
                sha256: pack.sha256,
                valhallaVersion: RegionStore.supportedValhallaVersion,
                installedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sidecarURL = regionsDir.appendingPathComponent("\(pack.id).json")
            try (try encoder.encode(sidecar)).write(to: sidecarURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }

    /// The mobile engine mmaps the tar and requires `index.bin` to be the
    /// first member. Read the first ustar header (name = bytes 0..<100).
    private static func verifyFirstTarMemberIsIndex(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 512), header.count == 512 else {
            throw TilePackError.notATilePack
        }
        let nameBytes = header.prefix(100).prefix { $0 != 0 }
        guard let name = String(bytes: nameBytes, encoding: .utf8), name == "index.bin" else {
            throw TilePackError.notATilePack
        }
    }
}
