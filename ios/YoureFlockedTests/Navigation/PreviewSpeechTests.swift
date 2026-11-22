#if DEBUG
import XCTest
@testable import YoureFlocked

private actor LongPreviewEngine: SpeechSynthesizing {
    let seconds: Double
    let failLoad: Bool
    init(seconds: Double, failLoad: Bool = false) { self.seconds = seconds; self.failLoad = failLoad }
    func load() async throws -> PhononSynthesizer.Load {
        if failLoad { throw PhononSynthesizer.Failure.missingModels }
        return .init(seconds: 0, compiled: false, voices: ["Easton", "Harper"])
    }
    func render(_ text: String, voice: String) async throws -> PhononSynthesizer.Render {
        .init(samples: Array(repeating: 0.1, count: Int(seconds * VoiceResampler.outputRate)),
              seconds: 0, firstAudio: 0, rtf: 0, peakBytes: 0, gainDB: 0, lufs: -16)
    }
}

@MainActor
final class PreviewSpeechTests: XCTestCase {
    /// The Settings preview is three prompts long (about 7 s). It used to be
    /// discarded by the five-second navigation limit, so every live preview
    /// timed out with "This voice could not render".
    func testPreviewLongerThanTheNavigationLimitStillPlays() async throws {
        let service = PhononSpeechService(engine: LongPreviewEngine(seconds: 7.4),
                                          applicationActive: { true }, automaticWanted: { false })
        let pcm = try await service.preview(.easton)
        XCTAssertEqual(Double(pcm.count) / VoiceResampler.outputRate, 7.4, accuracy: 0.01)
    }

    func testPreviewFailsFastWhenTheModelCannotLoad() async {
        let service = PhononSpeechService(engine: LongPreviewEngine(seconds: 1, failLoad: true),
                                          applicationActive: { true }, automaticWanted: { false })
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await service.preview(.harper)
            XCTFail("A preview with no loaded model must throw")
        } catch {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
}
#endif
