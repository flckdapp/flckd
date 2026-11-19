import XCTest
@testable import YoureFlocked

final class PromptTextTests: XCTestCase {
    func testEveryBundledClipHasASentence() throws {
        let directory = try XCTUnwrap(PromptVoice.male.url(for: "turn_left")).deletingLastPathComponent()
        let clipKeys = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4a" }.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(clipKeys.count, 435)
        XCTAssertEqual(PromptText.allKeys, clipKeys)
    }

    func testNoSentenceContainsADigit() {
        for key in PromptText.allKeys {
            let text = PromptText.sentence(for: key) ?? ""
            XCTAssertFalse(text.isEmpty, key)
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "\(key): \(text)")
        }
    }

    func testNumbersAreSpelledOut() {
        XCTAssertEqual(PromptText.sentence(for: "1000ft.turn_left"), "In one thousand feet, turn left.")
        XCTAssertEqual(PromptText.sentence(for: "continue_mi.1_25"), "Continue on this road for one and a quarter miles.")
    }
}
