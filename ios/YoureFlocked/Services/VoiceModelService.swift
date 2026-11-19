import CryptoKit
import Foundation

enum VoiceModelError: LocalizedError, Equatable {
    case notOffered
    case unavailable
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .notOffered: "This tile server doesn't offer the Kokoro voice."
        case .unavailable: "This build has no Kokoro voice."
        case .invalidArchive: "The downloaded voice files are unreadable. Try again."
        }
    }
}

/// Downloads the optional Kokoro voice from the configured tile server. Every
/// object is named in the descriptor bundled with the app and is installed
/// only if its sha256 matches; the server is never asked what to trust.
///
/// Requests happen only when the user taps a download button on the Kokoro
/// page. There is no update check and no timer. Like `TilePackService`, it
/// never falls back to the default server when another one is configured.
actor VoiceModelService {

    private let session: URLSession
    private let store: KokoroVoiceStore?
    private let base: URL?

    /// - Parameters:
    ///   - session: Injected by tests to observe requests.
    ///   - base: Injected by tests; defaults to the configured tile server.
    init(session: URLSession? = nil, store: KokoroVoiceStore? = .standard, base: URL? = TilePackService.serverBaseURL()) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3600
            config.httpAdditionalHeaders = ["User-Agent": TilePackService.userAgent]
            self.session = URLSession(configuration: config)
        }
        self.store = store
        self.base = base
    }

    /// Every preset's prompt clips. Presets already installed are skipped.
    func downloadClips(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let store else { throw VoiceModelError.unavailable }
        let presets = store.descriptor.presets.filter { !store.clipsInstalled(preset: KokoroPreset($0)) }
        let total = presets.reduce(Int64(0)) { $0 + $1.clips.bytes }
        try checkSpace(total, store: store)
        var done: Int64 = 0
        for preset in presets {
            let blob = KokoroPackDescriptor.Blob(path: preset.clips.path, bytes: preset.clips.bytes, sha256: preset.clips.sha256)
            let archive = try await fetch(blob)
            defer { try? FileManager.default.removeItem(at: archive) }
            let staging = store.packDirectory.appendingPathComponent(".staging-\(preset.id)", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            let count = try TarReader.extract(archive, to: staging)
            guard count == preset.clips.count else { throw VoiceModelError.invalidArchive }
            let destination = store.clipsDirectory(preset: preset.id)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            done += preset.clips.bytes
            progress(Double(done) / Double(max(total, 1)))
        }
    }

    /// The engine's model files, for spoken street names.
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let store else { throw VoiceModelError.unavailable }
        let files = store.descriptor.model.files
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        try checkSpace(total, store: store)
        let staging = store.packDirectory.appendingPathComponent(".staging-model", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var done: Int64 = 0
        for file in files {
            let target = staging.appendingPathComponent(file.name)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var whole = SHA256()
            for part in file.parts {
                let url = try await fetch(part)
                defer { try? FileManager.default.removeItem(at: url) }
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    whole.update(data: chunk)
                    try handle.write(contentsOf: chunk)
                }
                done += part.bytes
                progress(Double(done) / Double(max(total, 1)))
            }
            try handle.close()
            guard SpeedCameraFile.hex(whole.finalize()) == file.sha256 else {
                throw TilePackError.checksumMismatch(file.name)
            }
        }
        try? store.deleteModel()
        try FileManager.default.moveItem(at: staging, to: store.modelDirectory)
    }

    // MARK: Helpers

    func url(for path: String) throws -> URL {
        guard let base else { throw TilePackError.invalidServerURL }
        return base.appendingPathComponent(path)
    }

    /// Downloads one object to a temporary file and verifies it before
    /// returning. The caller owns, and deletes, the returned file.
    private func fetch(_ blob: KokoroPackDescriptor.Blob) async throws -> URL {
        let (downloaded, response) = try await session.download(from: try url(for: blob.path))
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: downloaded)
            if http?.statusCode == 404 { throw VoiceModelError.notOffered }
            throw TilePackError.serverError(http?.statusCode ?? -1)
        }
        // The system deletes its temporary file once this call returns.
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: downloaded, to: local)
        var hasher = SHA256()
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        guard SpeedCameraFile.hex(hasher.finalize()) == blob.sha256 else {
            try? FileManager.default.removeItem(at: local)
            throw TilePackError.checksumMismatch("Kokoro voice")
        }
        return local
    }

    private func checkSpace(_ bytes: Int64, store: KokoroVoiceStore) throws {
        let root = try store.prepareRoot()
        try FileManager.default.createDirectory(at: store.packDirectory, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage {
            // The archive and its unpacked copy coexist briefly.
            let needed = bytes * 2
            if available < needed { throw TilePackError.insufficientSpace(needed: needed, available: available) }
        }
    }
}

/// Reads the uncompressed ustar archives the pack's clips arrive in. Only
/// regular files with plain names are accepted; anything else is an error,
/// so an archive cannot write outside its directory.
enum TarReader {
    enum Error: Swift.Error, Equatable { case malformed, unsupportedMember(String) }

    static func entries(_ data: Data) throws -> [(name: String, data: Data)] {
        var result: [(name: String, data: Data)] = []
        var offset = data.startIndex
        while offset + 512 <= data.endIndex {
            let header = data[offset..<offset + 512]
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = string(header, 0, 100)
            let type = header[header.startIndex + 156]
            guard let size = Int(string(header, 124, 12).trimmingCharacters(in: .whitespaces), radix: 8) else {
                throw Error.malformed
            }
            guard type == UInt8(ascii: "0") || type == 0 else { throw Error.unsupportedMember(name) }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
                throw Error.unsupportedMember(name)
            }
            let start = offset + 512
            guard start + size <= data.endIndex else { throw Error.malformed }
            result.append((name, Data(data[start..<start + size])))
            offset = start + (size + 511) / 512 * 512
        }
        return result
    }

    /// Extracts into `directory` (created) and returns the number of files.
    @discardableResult
    static func extract(_ archive: URL, to directory: URL) throws -> Int {
        let members = try entries(try Data(contentsOf: archive))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for member in members {
            try member.data.write(to: directory.appendingPathComponent(member.name))
        }
        return members.count
    }

    private static func string(_ header: Data, _ start: Int, _ length: Int) -> String {
        let field = header[header.startIndex + start..<header.startIndex + start + length].prefix { $0 != 0 }
        return String(decoding: field, as: UTF8.self)
    }
}
