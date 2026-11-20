import XCTest
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

final class LiveSpeechTests: XCTestCase {
    func testVoiceMappingAndLegacySelection() {
        XCTAssertEqual(NavigationVoice.allCases, [.easton, .harper, .eric, .jessica])
        XCTAssertEqual(NavigationVoice.easton.recorded, .male)
        XCTAssertEqual(NavigationVoice.harper.recorded, .female)
        XCTAssertFalse(NavigationVoice.eric.live)
        XCTAssertFalse(NavigationVoice.jessica.live)
        XCTAssertEqual(VoiceMigration.selection(current: nil, oldEngine: "kokoro", oldPreset: nil, recorded: "female"), .easton)
        XCTAssertEqual(VoiceMigration.selection(current: nil, oldEngine: "recorded", oldPreset: nil, recorded: "female"), .jessica)
        XCTAssertEqual(VoiceMigration.selection(current: nil, oldEngine: nil, oldPreset: "heart", recorded: "male"), .easton)
        XCTAssertEqual(VoiceMigration.selection(current: "harper", oldEngine: "kokoro", oldPreset: "heart", recorded: nil), .harper)
        XCTAssertEqual(VoiceMigration.selection(current: nil, oldEngine: nil, oldPreset: nil, recorded: nil), .easton)
    }

    func testMigrationRemovesOldKeysAndOnlyOldPack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "speech-migration-\(UUID())"))
        let root = URL.applicationSupportDirectory.appendingPathComponent("speech-migration-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("voice/kokoro/old/model")
        let retained = root.appendingPathComponent("voice/other")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        defaults.set("kokoro", forKey: "voiceEngine")
        defaults.set("heart", forKey: "kokoroPreset")
        try VoiceMigration.run(defaults: defaults, support: root)
        XCTAssertEqual(NavigationVoice.selected(defaults), .easton)
        XCTAssertTrue(VoiceMigration.obsoleteKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        defaults.set("harper", forKey: NavigationVoice.storageKey)
        try VoiceMigration.run(defaults: defaults, support: root)
        XCTAssertEqual(NavigationVoice.selected(defaults), .harper)
    }

    func testReadyLateFailedThermalFallbackDecisions() {
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .ready, elapsed: 0, thermal: .nominal), .live)
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .pending, elapsed: 0, thermal: .nominal), .wait)
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .pending, elapsed: VoiceRenderPolicy.deadline, thermal: .nominal), .recorded)
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .failed, elapsed: 0, thermal: .nominal), .recorded)
        for thermal: ProcessInfo.ThermalState in [.serious, .critical] {
            XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .ready, elapsed: 0, thermal: thermal), .recorded)
        }
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: false, state: .ready, elapsed: 0, thermal: .nominal), .recorded)
        XCTAssertFalse(VoiceRenderPolicy.fits(audio: 6, recorded: 4, named: false))
        XCTAssertFalse(VoiceRenderPolicy.fits(audio: 4.6, recorded: 2, named: true))
        XCTAssertTrue(VoiceRenderPolicy.fits(audio: 4, recorded: 2, named: true))
    }

    func testBackgroundBreakerErrorsMissesSuccessAndForegroundReset() {
        var breaker = BackgroundSpeechBreaker()
        breaker.setForeground(false)
        breaker.record(success: false, deadlineMiss: false)
        breaker.record(success: true, deadlineMiss: true)
        XCTAssertTrue(breaker.allowsRender)
        breaker.record(success: true, deadlineMiss: false)
        XCTAssertEqual(breaker.failures, 0)
        for _ in 0..<BackgroundSpeechBreaker.threshold { breaker.record(success: false, deadlineMiss: false) }
        XCTAssertFalse(breaker.allowsRender)
        breaker.record(success: true, deadlineMiss: false)
        XCTAssertFalse(breaker.allowsRender, "An in-flight success must not close an open breaker")
        breaker.setForeground(true)
        XCTAssertTrue(breaker.allowsRender)
        XCTAssertEqual(breaker.failures, 0)
        XCTAssertEqual(breaker.activation, 1)
    }

    func testWindowAndPCMCacheEvictionDoNotRetainPassedNames() {
        XCTAssertEqual(Array(SpeechAheadPlanner.windowIndices(count: 10)), [0, 1, 2])
        XCTAssertEqual(Array(SpeechAheadPlanner.windowIndices(count: 0)), [])
        var cache = SpeechCache()
        cache.limit = 16
        let a = SpeechKey(voice: .easton, sentences: ["Example Street."])
        let b = SpeechKey(voice: .easton, sentences: ["Oak Avenue."])
        let c = SpeechKey(voice: .harper, sentences: ["Turn left."])
        cache.insert([0.1, 0.2], for: a)
        cache.insert([0.1, 0.2], for: b)
        cache.insert([0.1, 0.2], for: c)
        XCTAssertNil(cache.audio[a])
        XCTAssertEqual(cache.bytes, 16)
        cache.retain([c])
        XCTAssertNil(cache.audio[b])
        XCTAssertNotNil(cache.audio[c])
        cache.clear()
        XCTAssertTrue(cache.audio.isEmpty)
        XCTAssertEqual(cache.bytes, 0)
        cache.insert([0.1, 0.2], for: a)
        cache.insert([0.1, 0.2], for: b)
        cache.insert([0.1, 0.2], for: c, protecting: [a, b])
        XCTAssertNotNil(cache.audio[a])
        XCTAssertNil(cache.audio[c], "Generic warm-up must not evict the upcoming route")
    }

    func testWholeUtteranceIncludesNameExitAndLaneWithoutChangingFallbackClips() throws {
        let utterance = VoiceUtterance(clips: ["1mi.exit_right", "lane_right"], voice: .female, createdAt: 0,
            liveVoice: .harper, roadName: "US 999", exitNumber: "12B")
        let sentences = try XCTUnwrap(PromptSpeech.sentences(utterance))
        XCTAssertEqual(sentences.first, "In one mile, take exit twelve B on the right onto U S nine ninety nine.")
        XCTAssertEqual(sentences.last, PromptText.sentence(for: "lane_right"))
        XCTAssertEqual(utterance.clips, ["1mi.exit_right", "lane_right"])
    }

    func testPlannerNamesOnlyTheCurrentAndNextTwoStepsAndIncludesFinalAndCountdown() throws {
        let steps = (0..<4).map { index in
            SpeechAheadPlanner.Step(banner: VisualInstructionContent(text: ["Main Street", "Oak Avenue", "Park Road", "Example Boulevard"][index],
                maneuverType: .turn, maneuverModifier: .right, roundaboutExitDegrees: nil, laneInfo: nil, exitNumbers: []),
                lanes: nil, distance: 1000, exit: nil)
        }
        let requests = SpeechAheadPlanner.utterances(steps: steps, units: .imperial, voice: .harper, lanesEnabled: true, lightsEnabled: true)
        XCTAssertEqual(Set(requests.compactMap(\.roadName)), ["Main Street", "Oak Avenue", "Park Road"])
        XCTAssertTrue(requests.contains { $0.clips == ["turn_right"] })
        XCTAssertTrue(requests.contains { $0.clips == ["quarter_mi.turn_right"] })
        XCTAssertTrue(requests.contains { $0.clips == ["at_light.turn_right"] })
        XCTAssertTrue(requests.allSatisfy { $0.voice == .female && $0.liveVoice == .harper })
        XCTAssertTrue(requests.compactMap(PromptSpeech.sentences).flatMap { $0 }.allSatisfy(PhononSentences.accepts))
    }
}
