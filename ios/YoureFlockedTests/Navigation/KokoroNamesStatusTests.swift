import XCTest
@testable import YoureFlocked

final class KokoroNamesStatusTests: XCTestCase {
    func testStatusIgnoresRenderSpeed() throws {
        let gb: UInt64 = 1_000_000_000
        XCTAssertEqual(KokoroSupport.namesStatus(physicalMemory: 4 * gb, modelInstalled: true), .needsMoreMemory)
        XCTAssertEqual(KokoroSupport.namesStatus(physicalMemory: 4 * gb, modelInstalled: false), .needsMoreMemory)
        XCTAssertEqual(KokoroSupport.namesStatus(physicalMemory: 8 * gb, modelInstalled: false), .notInstalled)
        XCTAssertEqual(KokoroSupport.namesStatus(physicalMemory: 8 * gb, modelInstalled: true), .ready)

        // A slow measurement is recorded but never switches names off.
        let suite = "KokoroNamesStatus.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let descriptor = try XCTUnwrap(KokoroPackDescriptor.bundled)
        KokoroSupport.storeMeasurement(2.0, defaults, descriptor: descriptor)
        XCTAssertEqual(KokoroSupport.measuredRTF(defaults, descriptor: descriptor), 2.0)
        XCTAssertTrue(KokoroSupport.namesSupported(physicalMemory: 8 * gb))
        KokoroSupport.record(.cancelled, defaults, descriptor: descriptor)
        XCTAssertEqual(KokoroSupport.measuredRTF(defaults, descriptor: descriptor), 2.0)
        KokoroSupport.record(.rendered(samples: [0.1], rtf: 0.6), defaults, descriptor: descriptor)
        XCTAssertEqual(KokoroSupport.measuredRTF(defaults, descriptor: descriptor), 0.6)
    }

    func testPreviewSentenceAndLiveFirstClip() throws {
        XCTAssertEqual(VoiceUtterance.kokoroPreviewSentence(), "In five hundred feet, turn right onto Main Street.")
        XCTAssertEqual(VoiceUtterance.kokoroPreviewSentence(units: .metric), "In two hundred meters, turn right onto Main Street.")
        let root = TestDirectories.fresh()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KokoroVoiceStore(root: root, descriptor: try XCTUnwrap(KokoroPackDescriptor.bundled))
        let heart = try XCTUnwrap(KokoroPreset.named("heart"))
        let dir = store.clipsDirectory(preset: "heart")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let preview = VoiceUtterance.kokoroPreview(preset: heart, now: 0, firstClip: [0.5, 0.5])
        for key in preview.clips { try Data([1]).write(to: dir.appendingPathComponent("\(key).m4a")) }
        let loader = VoiceClipLoader(store: store, decode: { _, _ in [0.1] })
        let result = try loader.samples(for: preview)
        XCTAssertEqual(result.clips, [[0.5, 0.5], [0.1], [0.1]])
        XCTAssertTrue(result.kokoro)
    }
}
