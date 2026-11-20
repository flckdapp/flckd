import Synchronization
import XCTest
@testable import YoureFlocked

private actor ControlledSpeechEngine: SpeechSynthesizing {
    private(set) var loads = 0
    private(set) var renders = 0
    private var texts: [String] = []
    func calls(containing text: String) -> Int { texts.filter { $0.contains(text) }.count }
    private var held: CheckedContinuation<PhononSynthesizer.Render, Error>?
    func load() async throws -> PhononSynthesizer.Load {
        loads += 1
        return .init(seconds: 0, compiled: false, voices: ["Easton", "Harper"])
    }
    func render(_ text: String, voice: String) async throws -> PhononSynthesizer.Render {
        renders += 1
        texts.append(text)
        return try await withCheckedThrowingContinuation { held = $0 }
    }
    func finish(failed: Bool = false) {
        let c = held; held = nil
        if failed { c?.resume(throwing: PhononSynthesizer.Failure.emptyAudio) }
        else { c?.resume(returning: .init(samples: [0.2, 0.1], seconds: 0, firstAudio: 0,
                                        rtf: 0, peakBytes: 0, gainDB: 0, lufs: 0)) }
    }
}

@MainActor
final class SpeechReviewRegressionTests: XCTestCase {
    func testActivityManagerOptOutPreventsOSOwnedRequests() async {
        let manager = LiveActivityManager(activityRequestsEnabled: false)
        manager.startActivity(alertRadius: 200)
        await manager.updateNavigation(maneuverCode: 1, instruction: "Turn right.", distanceToNextTurn: 100, etaSecondsRemaining: 20)
        XCTAssertFalse(manager.isSupported)
        XCTAssertFalse(manager.isActivityRunning)
        await manager.endActivity()
    }

    func testCancelledAndStaleForegroundGrantsNeverStartQueuedOperation() async throws {
        let authorization = SpeechLoadAuthorization()
        let grant = try authorization.grant(applicationActive: true)
        authorization.transition(active: false)
        var invoked = false
        XCTAssertThrowsError(try authorization.perform(grant) { invoked = true })
        XCTAssertFalse(invoked)
        let next = try authorization.grant(applicationActive: true)
        let task = Task {
            try await Task.sleep(for: .milliseconds(5))
            try authorization.perform(next) { XCTFail("Cancelled operation started") }
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error type") }
        XCTAssertThrowsError(try authorization.grant(applicationActive: false))
    }

    func testCancelledNativeLoadCannotInstallEvenWhenQueued() async throws {
        let authorization = SpeechLoadAuthorization()
        let grant = try authorization.grant(applicationActive: true)
        let native = PhononNative()
        authorization.transition(active: false)
        do {
            _ = try await native.load(bundle: URL.applicationSupportDirectory.appendingPathComponent("does-not-exist"),
                                      authorization: authorization, grant: grant)
            XCTFail("Stale load started")
        } catch is CancellationError {} catch { XCTFail("Install was reached before authorization") }
        let cancelled = Task { let engine = PhononSynthesizer(); return try await engine.load() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled load started") } catch is CancellationError {} catch { XCTFail("Expected cancellation before install/load") }
    }

    func testOldRecordedEngineWinsOverLeftoverPreset() {
        for (raw, expected) in [("male", NavigationVoice.eric), ("female", .jessica)] {
            XCTAssertEqual(VoiceMigration.selection(current: nil, oldEngine: "recorded", oldPreset: "heart", recorded: raw), expected)
        }
    }

    func testCameraAtGuidanceBoundaryUsesRecordingWithoutAnotherDeadline() throws {
        var queue = VoicePromptQueue()
        let guidance = VoiceUtterance(clips: ["turn_right"], createdAt: 0)
        let camera = VoiceUtterance(clips: ["cam.flock.ahead"], priority: .camera, createdAt: 0.01, liveVoice: .easton)
        queue.enqueue(guidance)
        XCTAssertEqual(queue.next(now: 0), guidance)
        queue.enqueue(camera)
        let next = try XCTUnwrap(queue.next(now: 5))
        XCTAssertFalse(VoiceRenderPolicy.canResolveLive(next, now: 5))
        XCTAssertTrue(5 - next.createdAt < VoicePromptQueue.cameraLifetime)
        XCTAssertTrue(VoiceRenderPolicy.canResolveLive(next, now: 4.5))
    }

    func testEachBackgroundAttemptCountsOnlyOnceOnDeadlineThenError() {
        var breaker = BackgroundSpeechBreaker()
        breaker.setForeground(false)
        let key = SpeechKey(voice: .easton, sentences: ["Turn left."])
        for _ in 0..<2 {
            var attempt = SpeechAttempt(key: key, generation: 1, window: 1, background: true, activation: breaker.activation)
            attempt.account(success: false, deadlineMiss: true, breaker: &breaker)
            attempt.account(success: false, deadlineMiss: false, breaker: &breaker)
        }
        XCTAssertEqual(breaker.failures, 2)
        XCTAssertTrue(breaker.allowsRender)
        var third = SpeechAttempt(key: key, generation: 1, window: 1, background: true, activation: breaker.activation)
        third.account(success: false, deadlineMiss: false, breaker: &breaker)
        XCTAssertFalse(breaker.allowsRender)
    }

    func testAutomaticWarmUpRequiresLiveSelectionAndMasterButPreviewCanLoad() async throws {
        for voice in NavigationVoice.allCases {
            XCTAssertEqual(SpeechWarmUpPolicy.automatic(voice: voice, master: true, foreground: true), voice.live)
            XCTAssertFalse(SpeechWarmUpPolicy.automatic(voice: voice, master: false, foreground: true))
            XCTAssertFalse(SpeechWarmUpPolicy.automatic(voice: voice, master: true, foreground: false))
        }
        let engine = ControlledSpeechEngine()
        let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { false })
        service.setForeground(true)
        service.beginTrip()
        await Task.yield()
        let before = await engine.loads
        XCTAssertEqual(before, 0)
        service.warmUp(explicitPreview: true)
        for _ in 0..<30 where !service.loaded { await Task.yield() }
        let after = await engine.loads
        XCTAssertEqual(after, 1)
        service.endTrip()
    }

    private func settle(_ condition: () async -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !(await condition()), ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(2))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }

    private var named: VoiceUtterance {
        VoiceUtterance(clips: ["500ft.turn_right"], createdAt: 0, liveVoice: .easton, roadName: "Main Street")
    }

    private func readyService(_ engine: ControlledSpeechEngine) async throws -> PhononSpeechService {
        let service = PhononSpeechService(engine: engine, applicationActive: { true }, automaticWanted: { true })
        service.warmUp()
        try await settle { service.loaded }
        return service
    }

    func testDedupCompletesInValidWindowWithOneEngineCall() async throws {
        let engine = ControlledSpeechEngine()
        let service = try await readyService(engine)
        service.beginTrip()
        let prompt = named
        service.plan([prompt])
        for _ in 0..<5 where !service.debugState(for: prompt).active {
            await engine.finish()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await settle { service.debugState(for: prompt).active }
        let before = await engine.calls(containing: "Main Street")
        // resolve requests the active key without advancing the window.
        let waiter = Task { await service.resolve(prompt, recordedDuration: 3) }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(service.debugState(for: prompt).queued, 0)
        await engine.finish()
        _ = await waiter.value
        try await Task.sleep(for: .milliseconds(30))
        let count = await engine.calls(containing: "Main Street")
        XCTAssertEqual(count, before)
        service.endTrip()
        await engine.finish()
    }

    func testKeptInflightKeySurvivesWindowReplacementWithoutRerender() async throws {
        let engine = ControlledSpeechEngine()
        let service = try await readyService(engine)
        let prompt = named
        service.plan([prompt])
        try await settle { await engine.renders == 1 }
        service.plan([prompt, prompt])
        XCTAssertEqual(service.debugState(for: prompt).queued, 0)
        await engine.finish()
        try await settle { !service.debugState(for: prompt).active }
        XCTAssertTrue(service.debugState(for: prompt).cached)
        let count = await engine.renders
        XCTAssertEqual(count, 1)
        service.endTrip()
    }

    func testStaleFailureDuringTripDoesNotRetainPassedName() async throws {
        let engine = ControlledSpeechEngine()
        let service = try await readyService(engine)
        service.beginTrip()
        let prompt = named
        service.plan([prompt])
        // Generic warm-up may occupy the worker first; release it.
        for _ in 0..<5 where !service.debugState(for: prompt).active {
            await engine.finish()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await settle { service.debugState(for: prompt).active }
        service.plan([])
        await engine.finish(failed: true)
        try await settle { !service.debugState(for: prompt).active }
        XCTAssertFalse(service.debugState(for: prompt).failed)
        XCTAssertFalse(service.debugState(for: prompt).cached)
        service.endTrip()
        await engine.finish()
    }

    func testThreeQueuedBackgroundDeadlinesOpenBreaker() async throws {
        let engine = ControlledSpeechEngine()
        let service = try await readyService(engine)
        service.beginTrip()
        let prompts = ["Main Street", "Oak Avenue", "Park Road"].map {
            VoiceUtterance(clips: ["500ft.turn_right"], createdAt: 0, liveVoice: .easton, roadName: $0)
        }
        service.setForeground(false)
        // The generic render stays held; all three playback requests queue.
        for prompt in prompts { _ = await service.resolve(prompt, recordedDuration: 3) }
        XCTAssertEqual(service.debugState(for: prompts[0]).failures, 3)
        service.endTrip()
        await engine.finish()
    }

    func testForegroundRenderDeadlineCountsWhenItExpiresInBackgroundOnlyOnce() async throws {
        let engine = ControlledSpeechEngine()
        let service = try await readyService(engine)
        service.beginTrip()
        let prompt = named
        service.plan([prompt])
        try await settle { service.debugState(for: prompt).active }
        service.setForeground(false)
        _ = await service.resolve(prompt, recordedDuration: 3)
        XCTAssertEqual(service.debugState(for: prompt).failures, 1)
        await engine.finish(failed: true)
        try await settle { !service.debugState(for: prompt).active }
        XCTAssertEqual(service.debugState(for: prompt).failures, 1)
        service.endTrip()
    }

    func testRevocationWhileNativeExecutorIsOccupiedReachesPerformButNotOperation() async throws {
        let native = PhononNative()
        let authorization = SpeechLoadAuthorization()
        let grant = try authorization.grant(applicationActive: true)
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "native executor occupied")
        let holder = Task { await native.debugHoldExecutor(started: { started.fulfill() }, until: release) }
        await fulfillment(of: [started], timeout: 2)
        let reached = MutexBox()
        let operation = MutexBox()
        let queued = Task {
            try await native.debugAuthorizedOperation(authorization: authorization, grant: grant,
                reachedPerform: { reached.set() }, operation: { operation.set() })
        }
        await Task.yield()
        authorization.transition(active: false)
        release.signal()
        await holder.value
        do { try await queued.value; XCTFail("Revoked queued operation ran") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertTrue(reached.value)
        XCTAssertFalse(operation.value)
    }

    func testPlayerNearExpiryCameraBypassesResolverAndPlaysRecording() async throws {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: VoiceSettings.masterKey)
        let directions = defaults.object(forKey: VoiceSettings.directionsKey)
        defaults.set(true, forKey: VoiceSettings.masterKey)
        defaults.set(true, forKey: VoiceSettings.directionsKey)
        defer { if let old { defaults.set(old, forKey: VoiceSettings.masterKey) } else { defaults.removeObject(forKey: VoiceSettings.masterKey) } }
        defer { if let directions { defaults.set(directions, forKey: VoiceSettings.directionsKey) } else { defaults.removeObject(forKey: VoiceSettings.directionsKey) } }
        let player = VoicePromptPlayer()
        defer { player.stopAll() }
        var clock = 0.0
        var resolutionCalls = 0
        var played: [(VoiceUtterance, Bool)] = []
        player.debugNow = { clock }
        player.debugResolve = { _, _ in resolutionCalls += 1; return .init(samples: nil, reason: "test") }
        player.debugPlayback = { played.append(($0, $1)) }
        player.enqueue(VoiceUtterance(clips: ["turn_right"], createdAt: 0))
        try await settle { played.count == 1 }
        // Camera priority/lifetime pass through the real queue and player;
        // directions permission avoids unrelated global camera preferences.
        let camera = VoiceUtterance(clips: ["cam.flock.ahead"], priority: .camera, kind: .directions,
                                    createdAt: 0.01, liveVoice: .easton)
        player.enqueue(camera)
        clock = 5
        player.debugFinishCurrent()
        try await settle { played.count == 2 }
        XCTAssertEqual(resolutionCalls, 0)
        XCTAssertEqual(played.last?.0.clips, camera.clips)
        XCTAssertNil(played.last?.0.renderedPCM)
        XCTAssertEqual(played.last?.1, false)
    }
}

private final class MutexBox: Sendable {
    private let state = Mutex(false)
    func set() { state.withLock { $0 = true } }
    var value: Bool { state.withLock { $0 } }
}
