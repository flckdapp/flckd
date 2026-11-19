import Foundation

/// Which engine speaks: the recorded voices, or the optional Kokoro voice.
/// `PromptVoice` stays recorded-only and is always the fallback.
enum VoiceEngine: String, Sendable {
    case recorded, kokoro
    static let storageKey = "voiceEngine"

    static func selected(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .recorded
    }
}

/// The bundled `KokoroPack.json`, written by `scripts/voice-model/build_pack.py`.
/// Only files whose sha256 it lists are ever installed.
struct KokoroPackDescriptor: Codable, Sendable, Equatable {
    struct Blob: Codable, Sendable, Equatable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    struct Clips: Codable, Sendable, Equatable {
        let path: String
        let bytes: Int64
        let sha256: String
        let count: Int
    }

    struct Preset: Codable, Sendable, Equatable {
        let id: String
        let name: String
        let upstream: String
        let sid: Int
        let gainDB: Double
        let clips: Clips

        enum CodingKeys: String, CodingKey {
            case id, name, upstream, sid, clips
            case gainDB = "gain_db"
        }
    }

    struct ModelFile: Codable, Sendable, Equatable {
        let name: String
        let bytes: Int64
        let sha256: String
        let parts: [Blob]
    }

    struct Model: Codable, Sendable, Equatable {
        let files: [ModelFile]
    }

    let schema: Int
    let id: String
    let engine: String
    let presets: [Preset]
    let model: Model

    static let bundled: KokoroPackDescriptor? = load(.main)

    static func load(_ bundle: Bundle) -> Self? {
        guard let url = bundle.url(forResource: "KokoroPack", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var clipBytes: Int64 { presets.reduce(0) { $0 + $1.clips.bytes } }
    var modelBytes: Int64 { model.files.reduce(0) { $0 + $1.bytes } }
}

struct KokoroPreset: Equatable, Hashable, Sendable {
    static let storageKey = "kokoroPreset"
    static let defaultID = "heart"

    let id: String
    let name: String
    let sid: Int
    let gainDB: Double

    init(id: String, name: String, sid: Int, gainDB: Double) {
        self.id = id
        self.name = name
        self.sid = sid
        self.gainDB = gainDB
    }

    init(_ preset: KokoroPackDescriptor.Preset) {
        self.init(id: preset.id, name: preset.name, sid: preset.sid, gainDB: preset.gainDB)
    }

    static func all(_ descriptor: KokoroPackDescriptor? = .bundled) -> [KokoroPreset] {
        descriptor?.presets.map(KokoroPreset.init) ?? []
    }

    static func named(_ id: String, in descriptor: KokoroPackDescriptor? = .bundled) -> KokoroPreset? {
        all(descriptor).first { $0.id == id }
    }
}

/// What the user asked for, independent of what is installed. The player
/// decides per utterance whether Kokoro audio can actually play.
enum KokoroSelection {
    static func requested(_ defaults: UserDefaults = .standard,
                          descriptor: KokoroPackDescriptor? = .bundled) -> KokoroPreset? {
        guard VoiceEngine.selected(defaults) == .kokoro else { return nil }
        let stored = defaults.string(forKey: KokoroPreset.storageKey) ?? KokoroPreset.defaultID
        return KokoroPreset.named(stored, in: descriptor) ?? KokoroPreset.named(KokoroPreset.defaultID, in: descriptor)
    }

    static func isUsable(_ preset: KokoroPreset, store: KokoroVoiceStore? = .standard) -> Bool {
        store?.clipsInstalled(preset: preset) ?? false
    }
}

/// Owns the on-disk layout for the downloaded Kokoro pack:
///
///     Application Support/voice/kokoro/<packId>/clips/<preset>/<key>.m4a
///     Application Support/voice/kokoro/<packId>/model/<file>
///
/// The root carries the backup-exclusion flag: re-downloadable data must not
/// be backed up (iOS Data Storage Guidelines, QA1719).
struct KokoroVoiceStore: Sendable {
    struct ModelPaths: Sendable, Equatable {
        let model: String
        let voices: String
        let tokens: String
        let lexicon: String
    }

    let root: URL
    let descriptor: KokoroPackDescriptor

    static let modelFileNames = ["model.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "LICENSE"]

    static let standard: KokoroVoiceStore? = {
        guard let descriptor = KokoroPackDescriptor.bundled,
              let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return KokoroVoiceStore(root: base.appendingPathComponent("voice/kokoro", isDirectory: true),
                                descriptor: descriptor)
    }()

    var packDirectory: URL { root.appendingPathComponent(descriptor.id, isDirectory: true) }
    var modelDirectory: URL { packDirectory.appendingPathComponent("model", isDirectory: true) }

    func clipsDirectory(preset id: String) -> URL {
        packDirectory.appendingPathComponent("clips/\(id)", isDirectory: true)
    }

    /// Creates the root with the backup-exclusion flag, as `RegionStore` does.
    @discardableResult
    func prepareRoot() throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dir = root
            try dir.setResourceValues(values)
        }
        return root
    }

    func clipURL(preset: KokoroPreset, key: String) -> URL? {
        let url = clipsDirectory(preset: preset.id).appendingPathComponent("\(key).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func clipsInstalled(preset: KokoroPreset) -> Bool {
        guard let expected = descriptor.presets.first(where: { $0.id == preset.id })?.clips.count,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: clipsDirectory(preset: preset.id), includingPropertiesForKeys: nil) else { return false }
        return files.filter { $0.pathExtension == "m4a" }.count == expected
    }

    var anyClipsInstalled: Bool {
        KokoroPreset.all(descriptor).contains { clipsInstalled(preset: $0) }
    }

    func modelInstalled() -> Bool {
        let fm = FileManager.default
        return descriptor.model.files.allSatisfy { file in
            let path = modelDirectory.appendingPathComponent(file.name).path
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber else { return false }
            return size.int64Value == file.bytes
        }
    }

    func modelPaths() -> ModelPaths? {
        guard modelInstalled() else { return nil }
        func path(_ name: String) -> String { modelDirectory.appendingPathComponent(name).path }
        return ModelPaths(model: path("model.onnx"), voices: path("voices.bin"),
                          tokens: path("tokens.txt"), lexicon: path("lexicon-us-en.txt"))
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: packDirectory.path) {
            try FileManager.default.removeItem(at: packDirectory)
        }
    }

    func deleteModel() throws {
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
    }

    /// Packs from older descriptors can never be used again; reclaim the space.
    func removeStalePacks() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != descriptor.id {
            try? fm.removeItem(at: entry)
        }
    }
}

/// Resolves an utterance to decoded clips. Kokoro audio is used only when
/// every clip exists in the requested preset; otherwise the whole utterance
/// is the recorded voice. The two are never mixed (plan P7).
struct VoiceClipLoader {
    enum LoadError: Error, Equatable { case missingClip, kokoroUnavailable }

    var store: KokoroVoiceStore?
    var recordedURL: (PromptVoice, String) -> URL? = { voice, key in voice.url(for: key) }
    /// Decodes one clip; the first argument is a cache key.
    var decode: (String, URL) throws -> [Float]
    /// Street-name audio rendered ahead (preset, first clip key, spoken name).
    /// A cache read: playback never waits for a render.
    var namedAudio: ((KokoroPreset, String, String) -> [Float]?)? = nil
    var sampleRate = 44_100.0
    /// A named utterance must fit before a waiting camera alert expires (plan P5b).
    static let namedUtteranceLimit: TimeInterval = 5.0

    static func duration(_ clips: [[Float]], sampleRate: Double) -> TimeInterval {
        guard !clips.isEmpty else { return 0 }
        return Double(clips.reduce(0) { $0 + $1.count }) / sampleRate
            + VoiceTimeline.sentenceGap * Double(clips.count - 1)
    }

    func samples(for utterance: VoiceUtterance) throws -> (clips: [[Float]], kokoro: Bool, named: Bool) {
        if let preset = utterance.kokoro, let store {
            let urls = utterance.clips.map { store.clipURL(preset: preset, key: $0) }
            if !urls.isEmpty, urls.allSatisfy({ $0 != nil }) {
                let clips = try zip(utterance.clips, urls).map { key, url in
                    try decode("kokoro.\(preset.id)/\(key)", url!)
                }
                if utterance.kokoroOnly, let first = utterance.previewFirstClip, !first.isEmpty {
                    var previewed = clips
                    previewed[0] = first
                    return (previewed, true, false)
                }
                if utterance.roadName != nil || utterance.exitNumber != nil, let first = utterance.clips.first {
                    for label in SpokenRoadName.labels(firstKey: first, bannerText: utterance.roadName,
                                                       exitNumber: utterance.exitNumber) {
                        guard let audio = namedAudio?(preset, first, label), !audio.isEmpty else { continue }
                        var named = clips
                        named[0] = audio
                        if Self.duration(named, sampleRate: sampleRate) <= Self.namedUtteranceLimit {
                            return (named, true, true)
                        }
                    }
                }
                return (clips, true, false)
            }
        }
        if utterance.kokoroOnly { throw LoadError.kokoroUnavailable }
        let clips = try utterance.clips.map { key -> [Float] in
            guard let url = recordedURL(utterance.voice, key) else { throw LoadError.missingClip }
            return try decode("\(utterance.voice.rawValue)/\(key)", url)
        }
        return (clips, false, false)
    }
}

/// Per-trip figures for the arrival card. Counted when an utterance starts
/// playing; arrival prompts and previews are excluded (plan P13).
struct KokoroStats: Equatable, Sendable {
    var requested = 0
    var spoken = 0
    var named = 0

    static func counts(_ utterance: VoiceUtterance) -> Bool {
        guard utterance.kokoro != nil, utterance.priority == .guidance || utterance.priority == .camera else { return false }
        return !(utterance.clips.first?.hasPrefix("arrive") ?? false)
    }

    mutating func record(_ utterance: VoiceUtterance, playedKokoro: Bool, named wasNamed: Bool = false) {
        guard Self.counts(utterance) else { return }
        requested += 1
        if playedKokoro { spoken += 1 }
        if playedKokoro && wasNamed { named += 1 }
    }
}
