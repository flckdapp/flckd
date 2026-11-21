#if DEBUG
import XCTest
import UIKit
@testable import YoureFlocked

@MainActor
final class MultiPromptSpeechTests: XCTestCase {
    func testForegroundMultiStepTripPlaysOpeningFourGuidanceAndCamera() async throws {
        let defaults = UserDefaults.standard
        let keys = [NavigationVoice.storageKey, VoiceSettings.masterKey, VoiceSettings.directionsKey,
                    VoiceSettings.camerasKey, CameraVoiceType.flock.storageKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set("easton", forKey: NavigationVoice.storageKey)
        for key in keys.dropFirst() { defaults.set(true, forKey: key) }
        let service = PhononSpeechService(applicationActive: { true }, automaticWanted: { true })
        let player = VoicePromptPlayer()
        defer {
            player.stopAll(); service.endTrip()
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        player.updateContext(.init(navigating: true))
        player.debugResolve = { prompt in
            let result = await service.resolve(prompt)
            let state = service.debugState(for: prompt)
            print("MULTIPROMPT resolve kind=\(prompt.isOpening ? "opening" : prompt.priority == .camera ? "camera" : "guidance") step=\(prompt.guidanceContext?.step ?? -1) cached=\(state.cached) failures=\(state.failures) outcome=\(result.reason ?? "pcm")")
            return result
        }
        let route = UUID()
        var schedule = GuidancePromptSchedule()
        let opening = VoiceUtterance(clips: ["depart"], createdAt: ProcessInfo.processInfo.systemUptime,
                                    liveVoice: .easton, isOpening: true)
        service.beginTrip(opening: opening)
        player.enqueue(opening)
        try await wait { player.speechStats().spoken + player.speechStats().skipped.values.reduce(0, +) >= 1 }
        // Let the real AVAudioPlayerNode completion drain, not a mocked callback.
        try await wait { RoutingMetricsStore.shared.speechEvents.contains { $0.promptID == opening.playbackID && $0.stage == .completed } }
        let names = ["Example Boulevard", "Example Avenue", "Example Parkway", "Example Highway"]
        let planned = names.map {
            VoiceUtterance(clips: ["500ft.turn_right"], createdAt: 0, liveVoice: .easton, roadName: $0)
        }
        service.plan(planned)
        try await wait { planned.allSatisfy { service.debugState(for: $0).cached } }
        for step in 0..<4 {
            if step == 2 {
                service.setForeground(false)
                service.setForeground(true)
            }
            let context = GuidanceContext(route: route, step: step)
            player.updateGuidanceContext(context)
            let scheduled = schedule.update(step: step, length: 334, remaining: 150, speed: 8)
            XCTAssertEqual(scheduled, .approach("500ft", meters: 152.4))
            var prompt = planned[step]
            prompt.createdAt = ProcessInfo.processInfo.systemUptime
            prompt.guidanceContext = context
            print("MULTIPROMPT scheduled step=\(step) age=0 foreground=true")
            player.enqueue(prompt)
            try await wait { player.speechStats().spoken + player.speechStats().skipped.values.reduce(0, +) >= step + 2 }
            if player.speechStats().skipped.isEmpty {
                try await wait { RoutingMetricsStore.shared.speechEvents.contains { $0.promptID == prompt.playbackID && $0.stage == .completed } }
            }
        }
        let camera = VoiceUtterance(clips: ["cam.flock.ahead"], priority: .camera, kind: .camera(.flock),
                                   createdAt: ProcessInfo.processInfo.systemUptime, liveVoice: .easton)
        player.enqueue(camera)
        try await wait { player.speechStats().spoken + player.speechStats().skipped.values.reduce(0, +) >= 6 }
        let stats = player.speechStats()
        print("MULTIPROMPT final requested=\(stats.requested) played=\(stats.spoken) skips=\(stats.skipped)")
        XCTAssertEqual(stats.requested, 6)
        XCTAssertEqual(stats.spoken, 6, "Opening, four scheduled named directions and camera must all play")
        XCTAssertTrue(stats.skipped.isEmpty, "Foreground rendered guidance must not be discarded: \(stats.skipped)")
        try await wait { RoutingMetricsStore.shared.speechEvents.contains { $0.promptID == camera.playbackID && $0.stage == .completed } }
    }

    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ready())
    }
}
#endif
