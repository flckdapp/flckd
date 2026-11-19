import Foundation

/// Turns the turn card's road name into words the Kokoro engine can say, or
/// nothing. A name that cannot be said in full is never said in part (plan D5):
/// the prompt plays without it. Pure functions; the shared fixture
/// `YoureFlockedTests/Navigation/Fixtures/spoken-road-names.json` pins every rule
/// so the Android app can follow the same ones.
enum SpokenRoadName {

    // MARK: Stage 1: the name in the banner

    private static let candidateCharacters: Set<Character> = ["'", "-", ".", " "]

    /// The road name inside the banner's primary text, or nil if there is none.
    static func candidate(from bannerText: String) -> String? {
        var text = bannerText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasSuffix(".") else { return nil }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        if let separator = text.firstIndex(where: { $0 == "," || $0 == ";" || $0 == "/" }) {
            text = String(text[..<separator])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            text = String(text[..<open])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              text.allSatisfy({ $0.isLetter || $0.isASCII && $0.isNumber || candidateCharacters.contains($0) }) else { return nil }
        return text
    }

    // MARK: Stages 2-6: the words

    private static let routePrefixes: [String: String] = [
        "I": "Interstate", "US": "U S", "CR": "County Road", "SR": "State Route",
    ]

    /// The candidate as words, or nil if any token cannot be said.
    static func spoken(_ name: String) -> String? {
        let tokens = name.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        var words: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if let next, isNumber(next) {
                if let expansion = routePrefixes[token] {
                    words.append(expansion)
                    index += 1
                    continue
                }
                if token.count == 2, token.allSatisfy({ $0.isASCII && $0.isUppercase }) {
                    words.append("Highway")
                    index += 1
                    continue
                }
            }
            if isNumber(token), let value = Int(token) {
                words.append(cardinal(value))
            } else if let value = ordinalValue(token) {
                words.append(ordinal(value))
            } else if rejects(token) {
                return nil
            } else {
                words.append(token)
            }
            index += 1
        }
        return words.joined(separator: " ")
    }

    private static func isNumber(_ token: String) -> Bool {
        (1...4).contains(token.count) && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func rejects(_ token: String) -> Bool {
        if token.count == 1 { return true }
        if token.contains(".") { return true }
        if token.contains(where: { $0.isNumber }) { return true }
        let letters = token.filter(\.isLetter)
        if (2...4).contains(token.count), letters.count == token.count, token.allSatisfy(\.isUppercase) { return true }
        return false
    }

    // MARK: Numbers

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    private static func below100(_ n: Int) -> String {
        n < 20 ? ones[n] : tens[n / 10] + (n % 10 == 0 ? "" : " " + ones[n % 10])
    }

    /// A pair as it follows a leading number: "hundred", "oh five", "twelve".
    private static func pair(_ n: Int) -> String {
        n == 0 ? "hundred" : n < 10 ? "oh " + ones[n] : below100(n)
    }

    /// Road numbers read the local way: 412 is "four twelve", 3920 is "thirty nine twenty".
    static func cardinal(_ n: Int) -> String {
        switch n {
        case 0..<100: below100(n)
        case 100..<1000: ones[n / 100] + " " + pair(n % 100)
        default: below100(n / 100) + " " + pair(n % 100)
        }
    }

    private static func ordinalValue(_ token: String) -> Int? {
        let digits = token.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count), let value = Int(digits), value >= 1,
              token.dropFirst(digits.count) == ordinalSuffix(value) else { return nil }
        return value
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static let irregularOrdinals = ["one": "first", "two": "second", "three": "third", "five": "fifth",
                                            "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]

    /// "first", "thirty ninth", "one hundred second", "one hundredth".
    static func ordinal(_ n: Int) -> String {
        var words = (n >= 100 ? [ones[n / 100], "hundred"] : [])
        if n % 100 != 0 || n < 100 { words += below100(n % 100).split(separator: " ").map(String.init) }
        let last = words.removeLast()
        let converted: String
        if let irregular = irregularOrdinals[last] {
            converted = irregular
        } else if last.hasSuffix("y") {
            converted = String(last.dropLast()) + "ieth"
        } else {
            converted = last + "th"
        }
        return (words + [converted]).joined(separator: " ")
    }

    // MARK: Sentences

    /// "onto" or "to take" after the action, or nil when a name cannot follow it.
    static func connector(forAction action: String) -> String? {
        let onto = ["turn_", "slight_", "sharp_", "end_", "roundabout_", "merge_", "ramp_", "exit_"]
        if action == "continue" || onto.contains(where: action.hasPrefix) { return "onto" }
        if action.hasPrefix("keep_") { return "to take" }
        return nil
    }

    private static let approachDistances = Set((GuidancePromptSchedule.countdown + GuidancePromptSchedule.metricCountdown).map(\.key)
        + ["500ft", "100m"])

    /// The approach prompt with the road name, or nil if any of it cannot be said.
    /// `name` is the spoken name, the render cache's key.
    static func sentence(firstKey: String, bannerText: String, knows: (String) -> Bool,
                         prompt: (String) -> String? = PromptText.sentence(for:)) -> (text: String, name: String)? {
        sentences(firstKey: firstKey, bannerText: bannerText, exitNumber: nil, knows: knows, prompt: prompt).first
    }

    // MARK: Exit numbers

    /// "12" is "twelve", "12B" is "twelve B", "235A" is "two thirty five A".
    /// Anything else (ranges, words, five digits) is nil.
    static func exitWords(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        let rest = text.dropFirst(digits.count)
        guard (1...4).contains(digits.count), let value = Int(digits), rest.count <= 1,
              rest.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return rest.isEmpty ? cardinal(value) : "\(cardinal(value)) \(rest.uppercased())"
    }

    private static func isExit(_ action: String) -> Bool { action == "exit_left" || action == "exit_right" }

    /// The labels a rendered prompt can be cached under, best first: exit
    /// number with the road name, exit number alone, road name alone. Needs no
    /// word list, so the player can look audio up with the same labels the
    /// planner rendered under.
    static func labels(firstKey: String, bannerText: String?, exitNumber: String?) -> [String] {
        let action = firstKey.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let name = bannerText.flatMap(candidate(from:)).flatMap(spoken)
        if isExit(action), let exit = exitNumber.flatMap(exitWords) {
            return (name.map { ["exit \(exit) onto \($0)"] } ?? []) + ["exit \(exit)"]
        }
        return name.map { [$0] } ?? []
    }

    /// Every speakable approach sentence for this prompt, best first, each with
    /// its cache label. An exit with a number gets the number, with the road
    /// name when that can be said too, and on its own otherwise.
    static func sentences(firstKey: String, bannerText: String, exitNumber: String?, knows: (String) -> Bool,
                          prompt: (String) -> String? = PromptText.sentence(for:)) -> [(text: String, name: String)] {
        let parts = firstKey.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, approachDistances.contains(parts[0]),
              let connector = connector(forAction: parts[1]),
              let base = prompt(firstKey), base.hasSuffix(".") else { return [] }
        let name = candidate(from: bannerText).flatMap(spoken)
        var options: [(text: String, name: String)] = []
        if isExit(parts[1]), let exit = exitNumber.flatMap(exitWords), base.contains("take the exit on the") {
            let numbered = base.dropLast().replacingOccurrences(of: "take the exit on the", with: "take exit \(exit) on the")
            if let name { options.append(("\(numbered) \(connector) \(name).", "exit \(exit) onto \(name)")) }
            options.append(("\(numbered).", "exit \(exit)"))
        } else if let name {
            options.append(("\(base.dropLast()) \(connector) \(name).", name))
        }
        return options.filter { SpokenText.isSpeakable($0.text, knows: knows) }
    }

    /// Every word stages 3 and 4 and the connectors can produce.
    static let vocabulary: Set<String> = {
        var words = Set<String>()
        func add(_ phrase: String) { words.formUnion(phrase.lowercased().split(separator: " ").map(String.init)) }
        for n in 0...9999 { add(cardinal(n)) }
        for n in 1...999 { add(ordinal(n)) }
        routePrefixes.values.forEach(add)
        add("Highway")
        add("onto")
        add("to take")
        add("exit")
        "abcdefghijklmnopqrstuvwxyz".forEach { add(String($0)) }
        return words
    }()
}
