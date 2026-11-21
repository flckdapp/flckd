#if DEBUG
import XCTest
@testable import YoureFlocked

@MainActor
final class SpeechDiagnosticsTests: XCTestCase {
    func testSpeechTimelineSurvivesReopenAndTruncatedTailWithoutLeakingText() throws {
        let directory = URL.applicationSupportDirectory.appending(path: "speech-diagnostics-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "session.jsonl")
        let id = UUID()
        do {
            let store = RoutingMetricsStore(sessionURL: url)
            for stage in [SpeechDiagnosticEvent.Stage.requested, .played, .skipped] {
                store.recordSpeechEvent(.init(promptID: id, kind: .guidance, stage: stage,
                    reason: stage == .skipped ? "duration" : nil, breaker: BackgroundSpeechBreaker(), variant: .numberOnly))
            }
            store.recordSpeechRender(wall: 0.5, background: false, success: true, errorType: nil, deadlineMiss: false)
        }
        let tail = try FileHandle(forWritingTo: url)
        try tail.seekToEnd(); try tail.write(contentsOf: Data("{broken".utf8)); try tail.close()
        do {
            let recovered = RoutingMetricsStore(sessionURL: url)
            XCTAssertEqual(recovered.speechEvents.count, 3)
            XCTAssertEqual(recovered.speechRequested["foreground"], 1)
            XCTAssertEqual(recovered.speechPlayed["foreground"], 1)
            XCTAssertEqual(recovered.speechSkips["foreground.duration"], 1)
            XCTAssertEqual(recovered.lastSpeechSkip, "duration")
            XCTAssertEqual(recovered.speechRenders.count, 1)
            XCTAssertEqual(recovered.speechEvents[1].variant, .numberOnly)
            recovered.recordSpeechEvent(.init(promptID: UUID(), kind: .camera, stage: .skipped,
                reason: "Private input that must never be persisted", breaker: BackgroundSpeechBreaker()))
        }
        let final = RoutingMetricsStore(sessionURL: url)
        XCTAssertEqual(final.speechEvents.count, 4)
        XCTAssertEqual(final.lastSpeechSkip, "other")
        let data = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(data.contains("Private input"))
        for forbidden in ["roadName", "coordinates", "sentences", "clips", "fallbackText"] {
            XCTAssertFalse(data.contains(forbidden))
        }
        XCTAssertEqual(final.speechEvents.last?.kind, .camera)
    }

    func testForegroundBreakerCannotOpenAndInactiveGrantCanRecover() throws {
        var breaker = BackgroundSpeechBreaker()
        for _ in 0..<10 { breaker.record(success: false, deadlineMiss: true, now: 0) }
        XCTAssertTrue(breaker.canAttempt(now: 0))
        XCTAssertNil(breaker.retryAt)
        let authorization = SpeechLoadAuthorization()
        let grant = try authorization.grant(applicationActive: true)
        authorization.transition(active: false)
        XCTAssertThrowsError(try authorization.check(grant))
        authorization.transition(active: true)
        let restored = try authorization.grant(applicationActive: true)
        XCTAssertNoThrow(try authorization.check(restored))
    }
}
#endif
