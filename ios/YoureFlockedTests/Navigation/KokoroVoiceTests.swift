import XCTest
@testable import YoureFlocked

final class KokoroVoiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KokoroVoiceTests-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "KokoroVoiceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func store() throws -> KokoroVoiceStore {
        KokoroVoiceStore(root: root, descriptor: try XCTUnwrap(KokoroPackDescriptor.bundled))
    }

    private var heart: KokoroPreset { KokoroPreset.named("heart")! }

    /// Writes empty placeholder clips; the loader's decoder is stubbed.
    private func install(_ keys: [String], preset: KokoroPreset, in store: KokoroVoiceStore) throws {
        let dir = store.clipsDirectory(preset: preset.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for key in keys { try Data([1]).write(to: dir.appendingPathComponent("\(key).m4a")) }
    }

    private func loader(_ store: KokoroVoiceStore) -> VoiceClipLoader {
        VoiceClipLoader(store: store, recordedURL: { voice, key in URL(fileURLWithPath: "/recorded/\(voice.rawValue)/\(key)") },
                        decode: { cacheKey, _ in cacheKey.hasPrefix("kokoro.") ? [1] : [0] })
    }

    func testBundledDescriptorHasSixPresetsOfEveryClip() throws {
        let descriptor = try XCTUnwrap(KokoroPackDescriptor.bundled)
        XCTAssertEqual(descriptor.schema, 1)
        XCTAssertEqual(descriptor.presets.map(\.id), ["heart", "bella", "nicole", "fenrir", "michael", "puck"])
        XCTAssertEqual(Set(descriptor.presets.map(\.clips.count)), [435])
        XCTAssertEqual(Set(descriptor.model.files.map(\.name)), Set(KokoroVoiceStore.modelFileNames))
        XCTAssertNotNil(KokoroPreset.named(KokoroPreset.defaultID))
    }

    func testRequestedFollowsTheEngineSettingNotTheFiles() throws {
        try withDefaults { defaults in
            XCTAssertNil(KokoroSelection.requested(defaults))
            defaults.set(VoiceEngine.recorded.rawValue, forKey: VoiceEngine.storageKey)
            XCTAssertNil(KokoroSelection.requested(defaults))
            defaults.set(VoiceEngine.kokoro.rawValue, forKey: VoiceEngine.storageKey)
            XCTAssertEqual(KokoroSelection.requested(defaults)?.id, "heart")
            defaults.set("puck", forKey: KokoroPreset.storageKey)
            XCTAssertEqual(KokoroSelection.requested(defaults)?.id, "puck")
            defaults.set("not-a-preset", forKey: KokoroPreset.storageKey)
            XCTAssertEqual(KokoroSelection.requested(defaults)?.id, "heart")
        }
        XCTAssertFalse(KokoroSelection.isUsable(heart, store: try store()))
    }

    func testKokoroClipsPlayWhenEveryKeyIsInstalled() throws {
        let store = try store()
        try install(["500ft.turn_right", "lane_right"], preset: heart, in: store)
        var utterance = VoiceUtterance(clips: ["500ft.turn_right", "lane_right"], createdAt: 0)
        utterance.kokoro = heart
        let result = try loader(store).samples(for: utterance)
        XCTAssertTrue(result.kokoro)
        XCTAssertEqual(result.clips, [[1], [1]])
        var stats = KokoroStats()
        stats.record(utterance, playedKokoro: result.kokoro)
        XCTAssertEqual(stats, KokoroStats(requested: 1, spoken: 1, named: 0))
    }

    func testOneMissingKokoroClipMakesTheWholeUtteranceRecorded() throws {
        let store = try store()
        try install(["500ft.turn_right"], preset: heart, in: store)
        var utterance = VoiceUtterance(clips: ["500ft.turn_right", "lane_right"], voice: .female, createdAt: 0)
        utterance.kokoro = heart
        let result = try loader(store).samples(for: utterance)
        XCTAssertFalse(result.kokoro)
        XCTAssertEqual(result.clips, [[0], [0]])
        var stats = KokoroStats()
        stats.record(utterance, playedKokoro: result.kokoro)
        XCTAssertEqual(stats, KokoroStats(requested: 1, spoken: 0, named: 0))
    }

    func testKokoroOnlyNeverFallsBack() throws {
        let preview = VoiceUtterance.kokoroPreview(preset: heart, now: 0)
        XCTAssertTrue(preview.kokoroOnly)
        XCTAssertEqual(preview.kokoro, heart)
        XCTAssertThrowsError(try loader(try store()).samples(for: preview)) { error in
            XCTAssertEqual(error as? VoiceClipLoader.LoadError, .kokoroUnavailable)
        }
    }

    func testRecordedPreviewIgnoresTheKokoroSelection() {
        let preview = VoiceUtterance.preview(voice: .male, now: 0)
        XCTAssertNil(preview.kokoro)
        XCTAssertFalse(preview.kokoroOnly)
        XCTAssertEqual(VoiceUtterance.kokoroPreview(preset: heart, now: 0).clips, preview.clips)
    }

    func testArrivalsPreviewsAndRecordedRequestsAreNotCounted() {
        var stats = KokoroStats()
        for clips in [["arrive"], ["arrive_left"]] {
            var utterance = VoiceUtterance(clips: clips, createdAt: 0)
            utterance.kokoro = heart
            stats.record(utterance, playedKokoro: true)
        }
        stats.record(VoiceUtterance.kokoroPreview(preset: heart, now: 0), playedKokoro: true)
        stats.record(VoiceUtterance(clips: ["turn_left"], createdAt: 0), playedKokoro: false)
        XCTAssertEqual(stats, KokoroStats())
        var camera = VoiceUtterance(clips: ["cam.flock.ahead"], priority: .camera, kind: .camera(.flock), createdAt: 0)
        camera.kokoro = heart
        stats.record(camera, playedKokoro: true)
        XCTAssertEqual(stats, KokoroStats(requested: 1, spoken: 1, named: 0))
    }

    func testStorePathsInstallStateAndStalePacks() throws {
        let store = try store()
        try store.prepareRoot()
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertFalse(store.modelInstalled())
        XCTAssertNil(store.modelPaths())
        let stale = root.appendingPathComponent("kokoro-old")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try install(["turn_left"], preset: heart, in: store)
        store.removeStalePacks()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertNotNil(store.clipURL(preset: heart, key: "turn_left"))
        XCTAssertNil(store.clipURL(preset: heart, key: "turn_right"))
        try store.delete()
        XCTAssertNil(store.clipURL(preset: heart, key: "turn_left"))
    }
}

final class LicenceResourceTests: XCTestCase {
    func testKokoroLicenceShipsInTheApp() throws {
        let url = try XCTUnwrap(Bundle(for: VoicePromptPlayer.self).url(forResource: "kokoro-82m", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Apache License"))
    }
}
