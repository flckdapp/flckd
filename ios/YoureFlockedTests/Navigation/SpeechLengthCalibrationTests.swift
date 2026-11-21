#if DEBUG
import XCTest
@testable import YoureFlocked

@MainActor
final class SpeechLengthCalibrationTests: XCTestCase {
    func testSyntheticLengthCalibration() async throws {
        let engine = PhononSynthesizer()
        _ = try await engine.load()
        let texts = ["Turn right.", "Flock camera ahead.", "Head to the route.",
            "In five hundred feet, turn right onto Example Boulevard.",
            "In one mile, take exit twelve B on the right onto U S nine ninety nine.",
            "In one mile, take exit twelve B on the right.",
            "Continue on this road for one mile.",
            "In a quarter mile, turn left onto Example International Transportation Boulevard.",
            "At the next light, turn right. Use the right two lanes.",
            "In two miles, keep left to take Example Parkway.",
            "Take exit twelve B on the right.", "You have arrived."]
        for voice in ["Easton", "Harper"] {
            for text in texts {
                let r = try await engine.render(text, voice: voice)
                print("LENGTH_CAL voice=\(voice) chars=\(text.count) words=\(text.split(whereSeparator: \.isWhitespace).count) sentences=\(PhononSentences.split(text).count) seconds=\(Double(r.samples.count) / VoiceResampler.outputRate)")
            }
        }
        try await engine.unload()
    }
}
#endif
