import Foundation

/// NFC character gate shared by every on-device speech request.
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

    static func isSpeakable(_ text: String, knows: (String) -> Bool = { _ in true }) -> Bool {
        guard let words = words(text), !words.isEmpty else { return false }
        return words.allSatisfy(knows)
    }
}
