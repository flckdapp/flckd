#if DEBUG
import XCTest
@testable import YoureFlocked

final class PhononEvaluationTests: XCTestCase {
    func testSentenceBoundariesKeepAbbreviationsDecimalsAndExitSuffixes() {
        XCTAssertEqual(PhononSentences.split("Take exit twelve B. Flock camera ahead."),
                       ["Take exit twelve B.", "Flock camera ahead."])
        XCTAssertEqual(PhononSentences.split("Continue for 0.5 miles. Turn left."),
                       ["Continue for 0.5 miles.", "Turn left."])
        XCTAssertEqual(PhononSentences.split("Turn onto Example St. North. Flock camera ahead."),
                       ["Turn onto Example St. North.", "Flock camera ahead."])
        XCTAssertEqual(PhononSentences.split("Continue on U.S. Highway. Then turn onto Example Rd. North."),
                       ["Continue on U.S. Highway.", "Then turn onto Example Rd. North."])
        XCTAssertEqual(PhononSentences.split("Wait?! Go! Last fragment"), ["Wait?!", "Go!", "Last fragment"])
        XCTAssertEqual(PhononSentences.split("  \n "), [])
        XCTAssertEqual(PhononSentences.split("Turn left."), ["Turn left."])
        // Decimal splitting is pure; the engine's stricter character gate still rejects digits.
        XCTAssertFalse(PhononSentences.accepts("Continue for 0.5 miles."))
    }

    func testEvaluationSentenceJoinUsesExistingGap() {
        let rate = VoiceResampler.outputRate
        let clips = [[Float](repeating: 0.1, count: 1_000), [Float](repeating: 0.2, count: 1_000)]
        let result = VoicePCM.compose(clips, sampleRate: rate)
        let gap = Int((rate * VoiceTimeline.sentenceGap).rounded())
        XCTAssertEqual(result.count, 2_000 + gap)
        XCTAssertTrue(result[1_000..<(1_000 + gap)].allSatisfy { $0 == 0 })
        XCTAssertEqual(PhononSentences.voices, ["Easton", "Harper"])
    }
    func testTextGateSharesCharacterRulesWithoutLexicon() {
        XCTAssertTrue(PhononSentences.accepts("Uncatalogued words, hyphen-joined; O'Example!"))
        XCTAssertTrue(PhononSentences.accepts("Cafe\u{301} Street."))
        for text in ["", "   ", "---", "Turn 12.", "A\nB", "A\tB", "Hello 👋", "a/b", String(repeating: "a", count: 601)] {
            XCTAssertFalse(PhononSentences.accepts(text))
        }
    }

    func testAllFixtureCasesAreVisibleAndUseRoadNameBuilder() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "spoken-road-names", withExtension: "json"))
        let items = try PhononSentences.build(fixture: Data(contentsOf: url))
        XCTAssertEqual(items.filter { $0.recordedKey != nil }.count, 5)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("Candidate.") }.count, 11)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("Name.") }.count, 23)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("Action.") }.count, 14)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("Sentence.") }.count, 9)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("Exit number.") }.count, 9)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("Exit sentence ") }.count, 6)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertTrue(items.compactMap(\.text).allSatisfy(PhononSentences.accepts))
        XCTAssertNil(items.first { $0.id == "Candidate.8" }?.text)
        XCTAssertEqual(items.first { $0.id == "Sentence.0" }?.text,
                       SpokenRoadName.sentence(firstKey: "500ft.turn_right", bannerText: "Main Street", knows: { _ in true })?.text)
        // Unlike the old engine, Phonon does not reject an otherwise safe unknown word.
        XCTAssertNotNil(items.first { $0.id == "Sentence.4" }?.text)
        let multi = try XCTUnwrap(items.first { $0.id == "turn-camera" }?.text)
        XCTAssertEqual(PhononSentences.split(multi).count, 2)
    }

    func testLoudnessCalibrationAndSharedLimiter() throws {
        let rate = 44_100.0
        let sine = (0..<88_200).map { Float(0.1 * sin(2 * .pi * 997 * Double($0) / rate)) }
        let level = try XCTUnwrap(VoicePCM.evaluationLUFS(sine))
        // BS.1770: mono 997 Hz at 0 dBFS reads -3.01 LUFS.
        XCTAssertEqual(level, -23.01, accuracy: 0.05)
        let normalized = VoicePCM.applyGain(sine, db: -16 - level)
        XCTAssertEqual(try XCTUnwrap(VoicePCM.evaluationLUFS(normalized)), -16, accuracy: 0.01)
        XCTAssertNil(VoicePCM.evaluationLUFS([Float](repeating: 0, count: 20_000)))
        XCTAssertNil(VoicePCM.evaluationLUFS([.nan]))
        let limited = VoicePCM.applyGain([Float](repeating: 0.5, count: 44_100), db: 20)
        XCTAssertLessThanOrEqual(limited.map(abs).max() ?? 1, 0.660001) // geo-ok: PCM ceiling tolerance
    }

    func testDebugPCMUsesNormalLoaderWithoutPack() throws {
        var utterance = VoiceUtterance(clips: [], priority: .sample, kind: .preview, createdAt: 0)
        utterance.renderedPCM = [0.1, 0.2, 0.1]
        let loader = VoiceClipLoader(decode: { _, _ in XCTFail("Unexpected file decode"); return [] })
        XCTAssertEqual(try loader.samples(for: utterance), [[0.1, 0.2, 0.1]])
    }

    @MainActor
    func testBundledPhononRendersOnSimulator() async throws {
        let engine = PhononSynthesizer()
        let load = try await engine.load()
        XCTAssertEqual(load.voices, ["Easton", "Harper"])
        let voice = try XCTUnwrap(load.voices.first)
        let result = try await engine.render("Turn left.", voice: voice)
        XCTAssertFalse(result.samples.isEmpty)
        XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(result.samples.map(abs).max() ?? 1, 0.660001) // geo-ok: PCM ceiling tolerance
        XCTAssertGreaterThan(result.firstAudio, 0)
        XCTAssertGreaterThan(result.rtf, 0)
        var utterance = VoiceUtterance(clips: [], priority: .sample, kind: .preview, createdAt: 0)
        utterance.renderedPCM = result.samples
        let loader = VoiceClipLoader(decode: { _, _ in [] })
        XCTAssertEqual(try loader.samples(for: utterance).first?.count, result.samples.count)
        VoicePromptPlayer.shared.enqueue(utterance)
        VoicePromptPlayer.shared.cancel(.sample)
        let attachment = XCTAttachment(string: String(format:
            "Phonon simulator: compile=%@ load=%.3fs render=%.3fs first=%.3fs RTF=%.3f peak=%llu gain=%.2fdB output=%.2fLUFS frames=%d",
            load.compiled.description, load.seconds, result.seconds, result.firstAudio, result.rtf,
            result.peakBytes, result.gainDB, result.lufs, result.samples.count))
        attachment.name = "Phonon timing (no input text)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let multi = try await engine.render("Take exit twelve B. Flock camera ahead.", voice: "Harper")
        XCTAssertGreaterThan(multi.samples.count, Int(VoiceResampler.outputRate * VoiceTimeline.sentenceGap))
        XCTAssertTrue(multi.samples.allSatisfy(\.isFinite))
        let multiAttachment = XCTAttachment(string: String(format:
            "Harper two sentences: render=%.3fs first=%.3fs RTF=%.3f peak=%llu output=%.2fLUFS frames=%d",
            multi.seconds, multi.firstAudio, multi.rtf, multi.peakBytes, multi.lufs, multi.samples.count))
        multiAttachment.name = "Harper multi-sentence timing (no input text)"
        multiAttachment.lifetime = .keepAlways
        add(multiAttachment)
        try await engine.unload()
    }
}
#endif
