#if DEBUG
import UIKit
import XCTest
@testable import YoureFlocked

private actor VariantSpeechEngine: SpeechSynthesizing {
    private(set) var renders = 0
    let numberedSeconds: Double
    init(numberedSeconds: Double) { self.numberedSeconds = numberedSeconds }
    func load() async throws -> PhononSynthesizer.Load { .init(seconds: 0, compiled: false, voices: ["Easton"]) }
    func render(_ text: String, voice: String) async throws -> PhononSynthesizer.Render {
        renders += 1
        let seconds = text.contains("onto") ? 6.5 : text.contains("twelve") ? numberedSeconds : 0.1
        return .init(samples: Array(repeating: 0.1, count: Int(seconds * VoiceResampler.outputRate)),
                     seconds: 0, firstAudio: 0, rtf: 0, peakBytes: 0, gainDB: 0, lufs: -16)
    }
}

@MainActor
final class ShortSpeechVariantTests: XCTestCase {
    private func prompt() -> VoiceUtterance {
        VoiceUtterance(clips: ["1mi.exit_right"], createdAt: ProcessInfo.processInfo.systemUptime,
                       liveVoice: .easton, roadName: "US 999", exitNumber: "12B")
    }

    func testOverlongNamedExitPlaysNumberOnlyOrNameFreeWithoutSkipping() async throws {
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        let defaults = UserDefaults.standard
        let saved = [VoiceSettings.masterKey, VoiceSettings.directionsKey].map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: VoiceSettings.masterKey); defaults.set(true, forKey: VoiceSettings.directionsKey)
        defer {
            for (key, value) in zip([VoiceSettings.masterKey, VoiceSettings.directionsKey], saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (seconds, expected, count) in [(0.2, SpeechVariant.numberOnly, 1), (6.0, .nameFree, 2)] {
            let engine = VariantSpeechEngine(numberedSeconds: seconds)
            let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { true })
            let player = VoicePromptPlayer()
            defer { player.stopAll(); service.endTrip() }
            var prompt = prompt()
            var deadline = ProcessInfo.processInfo.systemUptime + 3
            service.warmUp()
            while !service.loaded, ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
            service.plan([prompt])
            // Allow render-ahead to cascade before this prompt is requested.
            while await engine.renders < count, ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
            deadline = ProcessInfo.processInfo.systemUptime + 3
            prompt.createdAt = ProcessInfo.processInfo.systemUptime
            player.debugResolve = { await service.resolve($0) }
            var played: SpeechVariant?
            player.debugPlayback = { utterance, live in
                XCTAssertTrue(live)
                played = utterance.speechVariant
                XCTAssertLessThanOrEqual(Double(utterance.renderedPCM?.count ?? 0) / VoiceResampler.outputRate, 5)
            }
            player.enqueue(prompt)
            while played == nil, player.speechStats().skipped.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertEqual(played, expected, "Overlong named speech must shorten, not disappear")
            XCTAssertTrue(player.speechStats().skipped.isEmpty, "Must not skip an overlong named prompt: \(player.speechStats().skipped)")
            let renders = await engine.renders
            XCTAssertEqual(renders, count, "Only render the next variant when its predecessor is too long")
        }
    }

    func testVariantOrderAndDeadlineAreSharedWithoutChangingPlaybackIdentity() throws {
        let full = prompt()
        let variants = PromptSpeech.variants(full)
        XCTAssertEqual(variants.map(\.variant), [.full, .numberOnly, .nameFree])
        XCTAssertTrue(variants[0].sentences[0].contains("onto"))
        XCTAssertFalse(variants[1].sentences[0].contains("onto"))
        XCTAssertTrue(variants[1].sentences[0].contains("twelve B"))
        XCTAssertFalse(variants[2].sentences[0].contains("twelve"))
        var resolved = full
        resolved.speechVariant = .nameFree
        XCTAssertEqual(resolved.playbackID, full.playbackID)
        XCTAssertEqual(VoiceRenderPolicy.remaining(resolved, now: full.createdAt + 2), 0)
        var freshness = LiveGuidanceFreshness(context: nil, latest: UUID())
        XCTAssertFalse(freshness.allows(resolved))
        freshness.latest = full.playbackID
        XCTAssertTrue(freshness.allows(resolved))
        var stats = SpeechStats()
        stats.record(resolved, live: true)
        XCTAssertEqual(stats.named, 0)
    }

    func testRealEngineLongExitRendersShorterAheadAndResolvesWithinOriginalDeadline() async throws {
        let service = PhononSpeechService(applicationActive: { true }, automaticWanted: { true })
        defer { service.endTrip() }
        service.warmUp()
        let end = ProcessInfo.processInfo.systemUptime + 25
        while !service.loaded, ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(10)) }
        var prompt = prompt()
        prompt.roadName = "Example International Transportation Boulevard"
        service.plan([prompt])
        while service.debugCachedVariant(for: prompt) == nil, ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        prompt.createdAt = ProcessInfo.processInfo.systemUptime
        let result = await service.resolve(prompt)
        XCTAssertNotNil(result.samples)
        XCTAssertNil(result.reason)
        XCTAssertNotEqual(result.variant, .full)
        XCTAssertLessThanOrEqual(Double(result.samples?.count ?? 0) / VoiceResampler.outputRate, 5)
        XCTAssertGreaterThan(SpeechLengthPrediction.preferred(PromptSpeech.variants(prompt)), 0,
                             "Clearly overlong full speech should not be rendered at all")
        print("SHORT_VARIANT real engine selected=\(result.variant?.rawValue ?? "none") audio=\(Double(result.samples?.count ?? 0) / VoiceResampler.outputRate) reason=\(result.reason ?? "none")")
    }

    func testPlainGuidanceRendersOnceAndVariantsCannotExtendExpiredDeadline() async throws {
        let engine = VariantSpeechEngine(numberedSeconds: 0.2)
        let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { true })
        defer { service.endTrip() }
        service.warmUp()
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !service.loaded, ProcessInfo.processInfo.systemUptime < end { await Task.yield() }
        let plain = VoiceUtterance(clips: ["turn_right"], createdAt: ProcessInfo.processInfo.systemUptime, liveVoice: .easton)
        service.plan([plain])
        let result = await service.resolve(plain)
        XCTAssertEqual(result.variant, .full)
        let count = await engine.renders
        XCTAssertEqual(count, 1)
        var expired = prompt()
        expired.createdAt = ProcessInfo.processInfo.systemUptime - 2.1
        let skipped = await service.resolve(expired)
        XCTAssertNil(skipped.samples)
        XCTAssertEqual(skipped.reason, "guidanceDeadline")
    }

    func testShorteningPreservesLaneSentencesAndOnlyAppliesToGuidance() throws {
        var guidance = prompt()
        guidance.clips.append("lane_right")
        let variants = PromptSpeech.variants(guidance)
        XCTAssertEqual(variants.count, 3)
        for option in variants { XCTAssertEqual(option.sentences.last, PromptText.sentence(for: "lane_right")) }
        guidance.exitNumber = nil
        XCTAssertEqual(PromptSpeech.variants(guidance).map(\.variant), [.full, .nameFree])
        guidance.priority = .camera
        XCTAssertEqual(PromptSpeech.variants(guidance).map(\.variant), [.full])
    }
}
#endif
