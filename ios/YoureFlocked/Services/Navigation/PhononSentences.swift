import Foundation

enum PhononSentences {
    #if DEBUG
    struct Item: Identifiable, Sendable {
        let id: String
        let title: String
        let text: String?
        let recordedKey: String?
    }

    static let promptKeys = ["turn_left", "500ft.turn_right", "lane_right", "cam.flock.ahead", "arrive"]
    #endif
    static let voices = ["Easton", "Harper"]

    /// Deterministic sentence boundaries, without linguistic services or logs.
    /// Keep road/title abbreviations, dotted initialisms and decimal points
    /// together. A lone exit suffix ("twelve B.") is a sentence ending.
    static func split(_ text: String) -> [String] {
        let characters = Array(text)
        let abbreviations: Set<String> = ["st", "rd", "ave", "blvd", "dr", "ln", "hwy", "pkwy",
                                          "mr", "mrs", "ms", "jr", "sr", "e.g", "i.e", "u.s"]
        var start = 0
        var result: [String] = []
        for index in characters.indices {
            let character = characters[index]
            guard character == "." || character == "!" || character == "?" else { continue }
            let next = index + 1
            if next < characters.count, ".!?".contains(characters[next]) { continue }
            if character == ".", next < characters.count {
                if index > 0, characters[index - 1].isNumber, characters[next].isNumber { continue }
                // Interior dots in U.S. / e.g. are not boundaries.
                if characters[next].isLetter { continue }
                let prefix = String(characters[start...index].dropLast())
                let token = prefix.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                if abbreviations.contains(token.lowercased()), characters[next...].contains(where: { !$0.isWhitespace }) {
                    continue
                }
            }
            let sentence = String(characters[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            start = next
        }
        if start < characters.count {
            let tail = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { result.append(tail) }
        }
        return result
    }

    static func accepts(_ text: String) -> Bool {
        // Same character rules, without a word-list restriction.
        // Bound evaluation work so an accidental paste cannot render for minutes.
        text.count <= 600 && SpokenText.isSpeakable(text, knows: { _ in true })
    }

    #if DEBUG
    static func load(bundle: Bundle = .main) throws -> [Item] {
        guard let url = bundle.url(forResource: "phonon-road-names", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try build(fixture: Data(contentsOf: url))
    }

    /// Uses the fixture inputs, not its expected strings. Rejected cases stay
    /// visible, but cannot send a partial name or raw digits to either engine.
    static func build(fixture: Data) throws -> [Item] {
        struct Pair: Decodable { let input: String; let output: String? }
        struct Sentence: Decodable { let firstKey: String; let banner: String; let exitNumber: String? }
        struct Fixture: Decodable {
            let candidate: [Pair]; let spoken: [Pair]; let connector: [Pair]
            let sentence: [Sentence]; let exitNumber: [Pair]; let exitSentence: [Sentence]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixture)
        var items = promptKeys.compactMap { key in
            PromptText.sentence(for: key).map { Item(id: key, title: $0, text: $0, recordedKey: key) }
        }
        if let turn = SpokenRoadName.sentences(firstKey: "1mi.exit_right", bannerText: "", exitNumber: "12B",
                                               knows: { _ in true }).first?.text,
           let camera = PromptText.sentence(for: "cam.flock.ahead") {
            items.append(Item(id: "turn-camera", title: "Turn, then camera alert",
                              text: "\(turn) \(camera)", recordedKey: nil))
        }
        func add(_ group: String, _ index: Int, _ text: String?) {
            items.append(Item(id: "\(group).\(index)", title: "\(group) \(index + 1)",
                              text: text, recordedKey: nil))
        }
        func sentence(_ key: String, _ banner: String, _ exit: String? = nil) -> String? {
            SpokenRoadName.sentences(firstKey: key, bannerText: banner, exitNumber: exit, knows: { _ in true }).first?.text
        }
        for (i, pair) in fixture.candidate.enumerated() { add("Candidate", i, sentence("500ft.turn_right", pair.input)) }
        for (i, pair) in fixture.spoken.enumerated() {
            add("Name", i, SpokenRoadName.spoken(pair.input).flatMap { name in
                PromptText.sentence(for: "500ft.turn_right").map { "\($0.dropLast()) onto \(name)." }
            })
        }
        for (i, pair) in fixture.connector.enumerated() { add("Action", i, sentence("500ft.\(pair.input)", "Main Street")) }
        for (i, row) in fixture.sentence.enumerated() { add("Sentence", i, sentence(row.firstKey, row.banner)) }
        for (i, pair) in fixture.exitNumber.enumerated() {
            add("Exit number", i, SpokenRoadName.exitWords(pair.input).flatMap { _ in sentence("1mi.exit_right", "Main Street", pair.input) })
        }
        for (i, row) in fixture.exitSentence.enumerated() {
            let variants = SpokenRoadName.sentences(firstKey: row.firstKey, bannerText: row.banner,
                                                    exitNumber: row.exitNumber, knows: { _ in true })
            if variants.isEmpty { add("Exit sentence", i, nil) }
            for (j, variant) in variants.enumerated() { add("Exit sentence \(i + 1)", j, variant.text) }
        }
        return items
    }
    #endif
}
