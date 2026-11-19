import Foundation

/// The check every sentence passes before it reaches the Kokoro engine (plan
/// P12). The engine logs words it cannot find, whatever its debug setting, so
/// nothing it might not know is ever sent: a road name must never reach a log.
///
/// The rules match the engine's at sherpa-onnx 2.0.1: text is NFC-normalised
/// and lowercased, and a word is a maximal run of letters and apostrophes;
/// every other character, punctuation included, is a boundary. Anything that
/// is not a letter, an apostrophe, a hyphen, a space or `, . ! ? ; :` fails.
enum SpokenText {
    private static let separators: Set<Character> = [" ", "-", ",", ".", "!", "?", ";", ":"]

    static func words(_ text: String) -> [String]? {
        var result: [String] = []
        var current = ""
        for character in text.precomposedStringWithCanonicalMapping.lowercased() {
            if character.isLetter || character == "'" {
                current.append(character)
            } else if separators.contains(character) {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                return nil
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func isSpeakable(_ text: String, knows: (String) -> Bool) -> Bool {
        guard let words = words(text), !words.isEmpty else { return false }
        return words.allSatisfy(knows)
    }
}

/// The word column of the pack's `lexicon-us-en.txt`, loaded with the engine.
struct KokoroLexicon: Sendable {
    let words: Set<String>

    init(words: Set<String>) {
        self.words = words
    }

    init?(contentsOfFile path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var words = Set<String>()
        words.reserveCapacity(200_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let word = line.split(separator: " ", maxSplits: 1).first {
                words.insert(String(word).precomposedStringWithCanonicalMapping)
            }
        }
        guard !words.isEmpty else { return nil }
        self.words = words
    }

    func knows(_ word: String) -> Bool { words.contains(word) }
}
