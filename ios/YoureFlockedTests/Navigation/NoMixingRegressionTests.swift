import XCTest
@testable import YoureFlocked

private actor WaitingLiveEngine: SpeechSynthesizing {
    var loading: CheckedContinuation<PhononSynthesizer.Load, Error>?
    var rendering: CheckedContinuation<PhononSynthesizer.Render, Error>?
    private(set) var texts: [String] = []
    private(set) var loads = 0
    func load() async throws -> PhononSynthesizer.Load {
        loads += 1
        return try await withCheckedThrowingContinuation { loading = $0 }
    }
    func render(_ text: String, voice: String) async throws -> PhononSynthesizer.Render {
        texts.append(text)
        return try await withCheckedThrowingContinuation { rendering = $0 }
    }
    func finishLoad() {
        let c = loading; loading = nil
        c?.resume(returning: .init(seconds: 0.6, compiled: false, voices: ["Easton", "Harper"]))
    }
    func finishRender(failed: Bool = false) {
        let c = rendering; rendering = nil
        if failed { c?.resume(throwing: PhononSynthesizer.Failure.emptyAudio) }
        else { c?.resume(returning: .init(samples: [0.1, 0.2], seconds: 0.1, firstAudio: 0.1,
                                         rtf: 0.1, peakBytes: 0, gainDB: 0, lufs: -16)) }
    }
}

@MainActor
final class NoMixingRegressionTests: XCTestCase {
    private func settle(_ condition: () async -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !(await condition()), ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(2))
        }
        let ready = await condition()
        XCTAssertTrue(ready)
    }

    func testLiveLoaderCannotChooseRecordingsForAnyFailureAndCountsSkips() throws {
        for voice in [NavigationVoice.easton, .harper] {
            XCTAssertNil(voice.recording)
            for reason in ["cold", "renderFailed", "guidanceDeadline", "breaker", "thermalCritical", "backgroundUnloaded"] {
                var decoded = false
                let loader = VoiceClipLoader(recordedURL: { _, _ in URL(fileURLWithPath: "/synthetic") },
                    decode: { _, _ in decoded = true; return [0.1] })
                let prompt = VoiceUtterance(clips: ["turn_left"], createdAt: 0, liveVoice: voice)
                XCTAssertThrowsError(try loader.samples(for: prompt), reason)
                XCTAssertFalse(decoded, reason)
                var stats = SpeechStats()
                stats.request(prompt); stats.skip(prompt, reason: reason)
                XCTAssertEqual(stats.requested, 1)
                XCTAssertEqual(stats.spoken, 0)
                XCTAssertEqual(stats.skipped[reason], 1)
            }
        }
    }

    func testLivePlayerSkipsEveryFailureWithoutRecordedOrSystemPlayback() async throws {
        let defaults = UserDefaults.standard
        let keys = [VoiceSettings.masterKey, VoiceSettings.directionsKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.set(true, forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let player = VoicePromptPlayer()
        defer { player.stopAll() }
        var played = 0
        var calls = 0
        var reason = "cold"
        player.debugPlayback = { _, _ in played += 1 }
        player.debugResolve = { _ in calls += 1; return .init(samples: nil, reason: reason) }
        for item in ["cold", "renderFailed", "guidanceDeadline", "breaker", "thermalCritical", "backgroundUnloaded"] {
            reason = item
            let before = calls
            player.enqueue(VoiceUtterance(clips: ["turn_left"], fallbackText: "Turn left.",
                createdAt: ProcessInfo.processInfo.systemUptime, liveVoice: .easton))
            try await settle { calls > before }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(played, 0)
        XCTAssertEqual(player.speechStats().requested, 6)
        XCTAssertEqual(player.speechStats().skipped.values.reduce(0, +), 6)
    }

    func testColdOpeningLoadsAndRendersFirstWithoutBlockingTripOrChoosingRecording() async throws {
        let engine = WaitingLiveEngine()
        var clock = 0.0
        let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { true }, now: { clock })
        let opening = VoiceUtterance(clips: ["depart"], createdAt: 0, liveVoice: .easton, isOpening: true)
        service.beginTrip(opening: opening)
        let turn = VoiceUtterance(clips: ["turn_right"], createdAt: 0, liveVoice: .easton)
        service.plan([turn])
        let resolution = Task { await service.resolve(opening) }
        try await settle { await engine.loads == 1 }
        clock = 0.6
        await engine.finishLoad()
        // A refreshed planner window must not push the opening behind a turn
        // after load completion has made the worker runnable.
        service.plan([turn])
        try await settle { await engine.texts.count == 1 }
        let first = await engine.texts.first
        XCTAssertEqual(first, PromptText.sentence(for: "depart"))
        clock = 1.2
        await engine.finishRender()
        let result = await resolution.value
        XCTAssertNotNil(result.samples)
        XCTAssertNil(result.reason)
        service.endTrip()
        await engine.finishRender()
    }

    func testOpeningDeadlineSkipsRatherThanWaitingForeverOrSwitchingVoice() async throws {
        let engine = WaitingLiveEngine()
        var clock = 0.0
        let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { true }, now: { clock })
        let opening = VoiceUtterance(clips: ["depart"], createdAt: 0, liveVoice: .harper, isOpening: true)
        service.beginTrip(opening: opening)
        let resolution = Task { await service.resolve(opening) }
        try await settle { await engine.loads == 1 }
        clock = 8.01
        XCTAssertEqual(VoiceRenderPolicy.remaining(opening, now: clock), 0)
        let result = await resolution.value
        XCTAssertNil(result.samples)
        XCTAssertEqual(result.reason, "openingDeadline")
        service.endTrip()
        await engine.finishLoad()
        await engine.finishRender()
    }

    func testLivePolicyWaitsTwoSecondsKeepsSeriousAndSkipsCritical() {
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .pending, elapsed: 1, thermal: .serious), .wait)
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .ready, elapsed: 1.9, thermal: .serious), .live)
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .pending, elapsed: 2, thermal: .nominal), .skip)
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .ready, elapsed: 0, thermal: .critical), .skip)
        XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: true, state: .failed, elapsed: 0, thermal: .nominal), .skip)
    }

    func testLiveServiceSkipsUnloadedBackgroundCriticalFailureAndOpenBreaker() async throws {
        let engine = WaitingLiveEngine()
        var clock = 0.0
        var thermal = ProcessInfo.ThermalState.nominal
        let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { true },
                                          now: { clock }, thermal: { thermal })
        let prompt = VoiceUtterance(clips: ["turn_left"], createdAt: 0, liveVoice: .harper)
        service.setForeground(false)
        var result = await service.resolve(prompt)
        XCTAssertNil(result.samples)
        XCTAssertEqual(result.reason, "backgroundUnloaded")
        thermal = .critical
        result = await service.resolve(prompt)
        XCTAssertEqual(result.reason, "thermalCritical")
        thermal = .serious
        service.setForeground(true)
        try await settle { await engine.loads == 1 }
        await engine.finishLoad()
        try await settle { service.loaded }
        // Failed engine audio is a skip even while serious rendering is allowed.
        let failed = Task { await service.resolve(prompt) }
        try await settle { await engine.texts.count == 1 }
        await engine.finishRender(failed: true)
        result = await failed.value
        XCTAssertNil(result.samples)
        XCTAssertEqual(result.reason, "renderFailed")
        service.beginTrip()
        service.setForeground(false)
        for index in 0..<3 {
            clock = Double(index) * 3
            let expired = VoiceUtterance(clips: ["turn_right"], createdAt: clock - 2.01, liveVoice: .harper)
            _ = await service.resolve(expired)
        }
        let current = VoiceUtterance(clips: ["turn_right"], createdAt: clock, liveVoice: .harper)
        result = await service.resolve(current)
        XCTAssertNil(result.samples)
        XCTAssertEqual(result.reason, "breaker")
        service.endTrip()
        await engine.finishRender()
    }

    func testStaleStepAndSupersededGuidanceNeverPlayAfterWait() async throws {
        let defaults = UserDefaults.standard
        let saved = [VoiceSettings.masterKey, VoiceSettings.directionsKey].map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: VoiceSettings.masterKey); defaults.set(true, forKey: VoiceSettings.directionsKey)
        defer {
            for (key, value) in zip([VoiceSettings.masterKey, VoiceSettings.directionsKey], saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let player = VoicePromptPlayer()
        defer { player.stopAll() }
        var held: CheckedContinuation<PhononSpeechService.Resolution, Never>?
        var played = 0
        player.debugResolve = { _ in await withCheckedContinuation { held = $0 } }
        player.debugPlayback = { _, _ in played += 1 }
        let route = UUID()
        let old = GuidanceContext(route: route, step: 0), next = GuidanceContext(route: route, step: 1)
        let prompt = VoiceUtterance(clips: ["turn_left"], createdAt: ProcessInfo.processInfo.systemUptime,
                                   liveVoice: .easton, guidanceContext: old)
        player.updateGuidanceContext(old)
        player.enqueue(prompt)
        try await settle { held != nil }
        let first = held; held = nil
        player.updateGuidanceContext(next)
        first?.resume(returning: .init(samples: [0.1], reason: nil))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(played, 0)
        player.enqueue(VoiceUtterance(clips: ["turn_left"], createdAt: ProcessInfo.processInfo.systemUptime,
                                     liveVoice: .easton, guidanceContext: next))
        try await settle { held != nil }
        let superseded = held; held = nil
        player.enqueue(VoiceUtterance(clips: ["turn_right"], createdAt: ProcessInfo.processInfo.systemUptime,
                                     liveVoice: .easton, guidanceContext: next))
        superseded?.resume(returning: .init(samples: [0.1], reason: nil))
        try await settle { held != nil }
        held?.resume(returning: .init(samples: [0.2], reason: nil)); held = nil
        try await settle { played == 1 }
        var freshness = LiveGuidanceFreshness(context: old, latest: UUID())
        XCTAssertFalse(freshness.allows(prompt))
        freshness.latest = prompt.playbackID
        XCTAssertTrue(freshness.allows(prompt))
    }

    func testCameraWaitsOnlyItsLifetimeAndGuidanceWaitYields() async throws {
        var clock = 0.0
        let engine = WaitingLiveEngine()
        let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { true }, now: { clock })
        service.warmUp()
        try await settle { await engine.loads == 1 }; await engine.finishLoad()
        try await settle { service.loaded }
        let camera = VoiceUtterance(clips: ["cam.flock.ahead"], priority: .camera, createdAt: 0, liveVoice: .easton)
        let waiting = Task { await service.resolve(camera) }
        try await settle { await engine.texts.count == 1 }
        clock = 4.9
        XCTAssertGreaterThan(VoiceRenderPolicy.remaining(camera, now: clock), 0)
        clock = 5
        XCTAssertEqual(VoiceRenderPolicy.remaining(camera, now: clock), 0)
        clock = 20
        let result = await waiting.value
        XCTAssertNil(result.samples)
        XCTAssertEqual(result.reason, "cameraExpired")
        let guidance = VoiceUtterance(clips: ["turn_left"], createdAt: 0, liveVoice: .easton)
        XCTAssertTrue(VoiceRenderPolicy.shouldYield(waiting: guidance, isPlaying: false, incoming: camera))
        XCTAssertFalse(VoiceRenderPolicy.shouldYield(waiting: guidance, isPlaying: true, incoming: camera))
        XCTAssertTrue(VoiceRenderPolicy.fits(audio: 4.9, priority: .guidance))
        XCTAssertTrue(VoiceRenderPolicy.fits(audio: 2.9, priority: .guidance))
        var queue = VoicePromptQueue()
        queue.enqueue(guidance); queue.enqueue(camera)
        XCTAssertEqual(queue.next(now: 0)?.priority, .camera)
        service.endTrip(); await engine.finishRender()
    }

    func testCameraPreemptsPendingGuidanceAndNeverWaitsBehindItsResolver() async throws {
        let defaults = UserDefaults.standard
        let keys = [VoiceSettings.masterKey, VoiceSettings.directionsKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.set(true, forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let player = VoicePromptPlayer()
        defer { player.stopAll() }
        var guidance: CheckedContinuation<PhononSpeechService.Resolution, Never>?
        var playedCamera = false
        player.debugResolve = { prompt in
            if prompt.priority == .camera { return .init(samples: [0.1], reason: nil) }
            return await withCheckedContinuation { guidance = $0 }
        }
        player.debugPlayback = { prompt, live in playedCamera = prompt.priority == .camera && live }
        player.enqueue(.init(clips: ["turn_left"], createdAt: ProcessInfo.processInfo.systemUptime, liveVoice: .easton))
        try await settle { guidance != nil }
        player.enqueue(.init(clips: ["cam.flock.ahead"], priority: .camera, createdAt: ProcessInfo.processInfo.systemUptime,
                             liveVoice: .easton))
        try await settle { playedCamera }
        guidance?.resume(returning: .init(samples: [0.2], reason: nil))
        guidance = nil
        XCTAssertTrue(playedCamera)
    }

    func testBreakerAllowsOneCooldownProbeAndRecoversOnSuccessOrForeground() {
        var breaker = BackgroundSpeechBreaker()
        breaker.setForeground(false)
        for _ in 0..<3 { breaker.record(success: false, deadlineMiss: true, now: 0) }
        XCTAssertFalse(breaker.canAttempt(now: 59))
        XCTAssertTrue(breaker.beginAttempt(now: 60))
        XCTAssertFalse(breaker.beginAttempt(now: 60))
        breaker.completeProbe(success: true, now: 61)
        XCTAssertTrue(breaker.canAttempt(now: 61))
        for _ in 0..<3 { breaker.record(success: false, deadlineMiss: false, now: 62) }
        XCTAssertFalse(breaker.canAttempt(now: 63))
        breaker.setForeground(true)
        XCTAssertTrue(breaker.canAttempt(now: 63))
    }

    func testRecordedVoicesRemainWholeClipsAndRetainTheirOwnMapping() throws {
        XCTAssertEqual(NavigationVoice.eric.recording, .male)
        XCTAssertEqual(NavigationVoice.jessica.recording, .female)
        for voice in [NavigationVoice.eric, .jessica] {
            let utterance = VoiceUtterance(clips: ["turn_left", "lane_left"], voice: try XCTUnwrap(voice.recording),
                                           createdAt: 0, liveVoice: voice)
            var decoded: [String] = []
            let loader = VoiceClipLoader(recordedURL: { _, key in URL(fileURLWithPath: "/\(key)") },
                decode: { key, _ in decoded.append(key); return [0.1] })
            XCTAssertEqual(try loader.samples(for: utterance), [[0.1], [0.1]])
            XCTAssertEqual(decoded, utterance.clips.map { "\(utterance.voice.rawValue)/\($0)" })
            XCTAssertEqual(VoiceRenderPolicy.decide(liveVoice: false, state: .failed, elapsed: 999, thermal: .critical), .recorded)
        }
    }
}
