import Foundation

/// Fit to 24 synthetic Easton/Harper simulator renders. The field timeline
/// has no text-length features, so it cannot supply a supervised length fit.
enum SpeechLengthPrediction {
    static func seconds(_ sentences: [String]) -> Double {
        let characters = sentences.joined(separator: " ").count
        return 0.8101 + 0.05352 * Double(characters) + 0.35 * Double(max(0, sentences.count - 1)) // geo-ok: fitted speech-length coefficients, not coordinates
    }

    static func preferred(_ variants: [(variant: SpeechVariant, sentences: [String])]) -> Int {
        variants.firstIndex { seconds($0.sentences) + 0.65 <= VoiceRenderPolicy.utteranceLimit }
            ?? max(0, variants.count - 1)
    }
}
