import XCTest
@testable import YoureFlocked

final class StubKokoroEngine: KokoroEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var output: (samples: [Float], sampleRate: Int)? = (Array(repeating: 0.1, count: 24_000), 24_000)

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return texts }

    func generate(text: String, sid: Int) -> (samples: [Float], sampleRate: Int)? {
        lock.lock(); texts.append(text); lock.unlock()
        return output
    }
}

final class KokoroSynthesizerTests: XCTestCase {
    private let lexicon = KokoroLexicon(words: ["in", "five", "hundred", "feet", "turn", "right", "onto", "main", "street", "exam", "you're", "café"])

    func testGainIsAppliedAndPeaksNeverPassTheCeiling() {
        XCTAssertEqual(VoicePCM.applyGain([0.1, -0.2], db: 0), [0.1, -0.2])
        XCTAssertEqual(VoicePCM.applyGain([0.1], db: 20 * log10(2))[0], 0.2, accuracy: 1e-6)

        var samples = [Float](repeating: 0.01, count: 44_100)
        samples[22_050] = 0.5
        let limited = VoicePCM.applyGain(samples, db: 20)
        XCTAssertLessThanOrEqual(limited.map(abs).max()!, 0.66 + 1e-6)
        // Far from the peak, the full gain applies.
        XCTAssertEqual(limited[0], 0.1, accuracy: 1e-5)
        XCTAssertEqual(limited[44_099], 0.1, accuracy: 1e-5)
        // Just before it, the limiter is already reducing.
        XCTAssertLessThan(abs(limited[22_049]), 0.1)
    }

    func testWordsFollowTheEngineBoundaries() {
        XCTAssertEqual(SpokenText.words("In five hundred feet, turn right."), ["in", "five", "hundred", "feet", "turn", "right"])
        XCTAssertEqual(SpokenText.words("make a U-turn"), ["make", "a", "u", "turn"])
        XCTAssertEqual(SpokenText.words("You're here"), ["you're", "here"])
        // Decomposed é becomes the precomposed form the word list uses.
        XCTAssertEqual(SpokenText.words("Cafe\u{301}"), ["café"])
        XCTAssertTrue(SpokenText.isSpeakable("Cafe\u{301}", knows: lexicon.knows))
        // Punctuation inside a word splits it, as in the engine.
        XCTAssertEqual(SpokenText.words("exam!ple"), ["exam", "ple"])
        XCTAssertFalse(SpokenText.isSpeakable("exam!ple", knows: lexicon.knows))
        XCTAssertNil(SpokenText.words("You\u{2019}re here"))
        XCTAssertNil(SpokenText.words("In 500 feet"))
        XCTAssertNil(SpokenText.words("Main (old)"))
        XCTAssertFalse(SpokenText.isSpeakable("", knows: lexicon.knows))
        XCTAssertFalse(SpokenText.isSpeakable("...", knows: lexicon.knows))
    }

    func testUnknownWordsNeverReachTheEngine() {
        let engine = StubKokoroEngine()
        let synthesizer = KokoroSynthesizer(factory: { [lexicon] in (engine, lexicon) })
        let preset = KokoroPreset(id: "heart", name: "Heart", sid: 3, gainDB: 0)
        synthesizer.queue.sync {
            XCTAssertTrue(synthesizer.loadOnQueue())
            XCTAssertNil(synthesizer.render("In five hundred feet, turn right onto Exam!ple Street.", preset: preset, knows: lexicon.knows))
            XCTAssertNil(synthesizer.render("Turn right onto Elm Street.", preset: preset, knows: lexicon.knows))
            XCTAssertNil(synthesizer.render("In 500 feet.", preset: preset, knows: lexicon.knows))
        }
        XCTAssertEqual(engine.calls, [])
        let result = synthesizer.queue.sync {
            synthesizer.render("In five hundred feet, turn right onto Main Street.", preset: preset, knows: lexicon.knows)
        }
        XCTAssertEqual(engine.calls.count, 1)
        let output = try? XCTUnwrap(result)
        XCTAssertEqual(Double(output?.samples.count ?? 0), 44_100, accuracy: 441)
        XCTAssertGreaterThan(output?.rtf ?? -1, 0)
    }

    func testRenderWithoutALoadedEngineReturnsNothing() {
        let synthesizer = KokoroSynthesizer(factory: { nil })
        let preset = KokoroPreset(id: "heart", name: "Heart", sid: 3, gainDB: 0)
        synthesizer.queue.sync {
            XCTAssertFalse(synthesizer.loadOnQueue())
            XCTAssertNil(synthesizer.render("Turn right.", preset: preset, knows: { _ in true }))
        }
    }

    func testResampledLengthMatchesTheRateRatio() {
        let input = (0..<24_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        let output = KokoroSynthesizer.resample(input, from: 24_000, to: 44_100)
        XCTAssertEqual(Double(output.count), 44_100, accuracy: 441)
    }
}
