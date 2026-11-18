import XCTest
@testable import YoureFlocked

final class VoiceBundleTests: XCTestCase {
    func testVoicesHaveMatchingKeysButDifferentAudio() throws {
        let male = try XCTUnwrap(PromptVoice.male.url(for: "turn_left"))
        let female = try XCTUnwrap(PromptVoice.female.url(for: "turn_left"))
        XCTAssertNotEqual(male, female)
        XCTAssertNotEqual(try Data(contentsOf: male), try Data(contentsOf: female))
        func keys(_ url: URL) throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                           includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "m4a" }.map { $0.deletingPathExtension().lastPathComponent })
        }
        let maleKeys = try keys(male)
        XCTAssertEqual(maleKeys.count, 238)
        XCTAssertEqual(maleKeys, try keys(female))
    }
}
