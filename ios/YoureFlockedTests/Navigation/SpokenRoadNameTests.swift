import XCTest
@testable import YoureFlocked

final class SpokenRoadNameTests: XCTestCase {
    private struct Case: Decodable {
        let input: String
        let output: String?
    }

    private struct SentenceCase: Decodable {
        let firstKey: String
        let banner: String
        let output: String?
        let name: String?
    }

    private struct ExitSentenceCase: Decodable {
        let firstKey: String
        let banner: String
        let exitNumber: String?
        let outputs: [[String]]
    }

    private struct Fixture: Decodable {
        let exitNumber: [Case]
        let exitSentence: [ExitSentenceCase]
        let candidate: [Case]
        let spoken: [Case]
        let connector: [Case]
        let sentenceKnownWords: [String]
        let sentence: [SentenceCase]
        let vocabulary: [String]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "spoken-road-names", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testCandidateCases() throws {
        for c in try fixture().candidate {
            XCTAssertEqual(SpokenRoadName.candidate(from: c.input), c.output, c.input)
        }
    }

    func testSpokenCases() throws {
        for c in try fixture().spoken {
            XCTAssertEqual(SpokenRoadName.spoken(c.input), c.output, c.input)
        }
    }

    func testConnectorCases() throws {
        for c in try fixture().connector {
            XCTAssertEqual(SpokenRoadName.connector(forAction: c.input), c.output, c.input)
        }
    }

    func testSentenceCases() throws {
        let fixture = try fixture()
        let known = Set(fixture.sentenceKnownWords)
        for c in fixture.sentence {
            let result = SpokenRoadName.sentence(firstKey: c.firstKey, bannerText: c.banner, knows: known.contains)
            XCTAssertEqual(result?.text, c.output, "\(c.firstKey) \(c.banner)")
            XCTAssertEqual(result?.name, c.name, "\(c.firstKey) \(c.banner)")
        }
    }

    func testExitNumberCases() throws {
        for c in try fixture().exitNumber {
            XCTAssertEqual(SpokenRoadName.exitWords(c.input), c.output, c.input)
        }
    }

    func testExitSentencesAndTheLabelsThePlayerLooksUp() throws {
        let fixture = try fixture()
        let known = Set(fixture.sentenceKnownWords)
        for c in fixture.exitSentence {
            let sentences = SpokenRoadName.sentences(firstKey: c.firstKey, bannerText: c.banner, exitNumber: c.exitNumber,
                                                     knows: known.contains)
            XCTAssertEqual(sentences.map { [$0.text, $0.name] }, c.outputs, c.firstKey)
            // Every label the planner renders under is one the player will try.
            let labels = SpokenRoadName.labels(firstKey: c.firstKey, bannerText: c.banner, exitNumber: c.exitNumber)
            for sentence in sentences { XCTAssertTrue(labels.contains(sentence.name), sentence.name) }
        }
    }

    func testAnUnknownWordDropsTheWholeName() {
        let known: Set<String> = ["in", "five", "hundred", "feet", "turn", "right", "onto", "street"]
        XCTAssertNil(SpokenRoadName.sentence(firstKey: "500ft.turn_right", bannerText: "Main Street", knows: known.contains))
        XCTAssertNotNil(SpokenRoadName.sentence(firstKey: "500ft.turn_right", bannerText: "Main Street",
                                                knows: known.union(["main"]).contains))
    }

    func testVocabularyCoversEveryNumberOrdinalAndPrefix() throws {
        func words(_ phrase: String) -> Set<String> { Set(phrase.lowercased().split(separator: " ").map(String.init)) }
        var emitted = Set<String>()
        for n in 0...9999 { emitted.formUnion(words(SpokenRoadName.cardinal(n))) }
        for n in 1...999 { emitted.formUnion(words(SpokenRoadName.ordinal(n))) }
        for exit in ["1A", "9Z", "12"] {
            emitted.formUnion(words(SpokenRoadName.exitWords(exit) ?? ""))
        }
        emitted.insert("exit")
        for prefix in ["I", "US", "CR", "SR", "XX"] {
            emitted.formUnion(words(SpokenRoadName.spoken("\(prefix) 1") ?? ""))
        }
        for action in GuidancePromptSelector.actions {
            emitted.formUnion(words(SpokenRoadName.connector(forAction: action) ?? ""))
        }
        XCTAssertTrue(emitted.isSubset(of: SpokenRoadName.vocabulary), "\(emitted.subtracting(SpokenRoadName.vocabulary))")
        XCTAssertEqual(Set(try fixture().vocabulary), SpokenRoadName.vocabulary)
        XCTAssertTrue(SpokenRoadName.vocabulary.allSatisfy { !$0.contains("-") })
    }

    func testNumberReadings() {
        XCTAssertEqual(SpokenRoadName.cardinal(0), "zero")
        XCTAssertEqual(SpokenRoadName.cardinal(412), "four twelve")
        XCTAssertEqual(SpokenRoadName.cardinal(2000), "twenty hundred")
        XCTAssertEqual(SpokenRoadName.cardinal(2005), "twenty oh five")
        XCTAssertEqual(SpokenRoadName.ordinal(1), "first")
        XCTAssertEqual(SpokenRoadName.ordinal(12), "twelfth")
        XCTAssertEqual(SpokenRoadName.ordinal(20), "twentieth")
        XCTAssertEqual(SpokenRoadName.ordinal(111), "one hundred eleventh")
    }

    func testApproachThresholdsMatchTheSchedule() {
        XCTAssertEqual(GuidancePromptSchedule.approachThresholds(length: 5000, units: .imperial).map(\.key),
                       ["2mi", "1mi", "half_mi", "quarter_mi"])
        XCTAssertEqual(GuidancePromptSchedule.approachThresholds(length: 1000, units: .imperial).map(\.key),
                       ["half_mi", "quarter_mi"])
        XCTAssertEqual(GuidancePromptSchedule.approachThresholds(length: 300, units: .imperial).map(\.key), ["500ft"])
        XCTAssertEqual(GuidancePromptSchedule.approachThresholds(length: 100, units: .imperial).map(\.key), [])
        XCTAssertEqual(GuidancePromptSchedule.approachThresholds(length: 150, units: .metric).map(\.key), ["100m"])
        XCTAssertEqual(GuidancePromptSchedule.approachThresholds(length: 2500, units: .metric).map(\.key),
                       ["2km", "1km", "500m", "200m"])
    }
}
