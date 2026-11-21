#if DEBUG
import CoreLocation
import XCTest
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

private actor FastDriveSpeechEngine: SpeechSynthesizing {
    private(set) var renders = 0
    var delay: Bool
    let overlongNamed: Bool
    init(delay: Bool = false, overlongNamed: Bool = false) { self.delay = delay; self.overlongNamed = overlongNamed }
    func load() async throws -> PhononSynthesizer.Load { .init(seconds: 0, compiled: false, voices: ["Easton"]) }
    func render(_ text: String, voice: String) async throws -> PhononSynthesizer.Render {
        renders += 1
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        return .init(samples: Array(repeating: 0.1, count: overlongNamed && text.contains("onto") ? 264600 : 4410), seconds: 0, firstAudio: 0, rtf: 0, peakBytes: 0, gainDB: 0, lufs: -16)
    }
}

@MainActor
final class LockedDriveRegressionTests: XCTestCase {
    private func point(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        .init(latitude: north / 111_320, longitude: east / 111_320)
    }
    func testTwoVisibleThreeNearbyAgreeForPreviewSpeechAndActualPassCount() async throws {
        let path = [point(0, 0), point(600, 0)]
        let cameras = [(100.0, 5.0, "270"), (400.0, 5.0, "270"), (200.0, 60.0, "180"),
                       (300.0, 0.0, "0"), (500.0, 80.0, "270")].enumerated().map { index, value in
            SurveillanceCamera(osmID: Int64(index + 1), latitude: point(value.0, value.1).latitude,
                longitude: point(value.0, value.1).longitude,
                tags: ["surveillance:type": index == 1 ? "camera" : "ALPR", "direction": value.2, "brand": "Flock"])
        }
        let preview = CameraObservability.RouteExposure.build(path: path, cameras: cameras)
        XCTAssertEqual(preview.exposedIDs, [1, 2])
        let engine = ProximityAlertEngine()
        engine.voiceContext = { .init(navigating: true) }
        engine.setSpeechRoute(path, cameras: cameras)
        await engine.waitForExposure()
        let store = CameraStore(); store.cameras = cameras
        let defaults = UserDefaults.standard
        let keys = [VoiceSettings.masterKey, VoiceSettings.camerasKey, "spokenCamera_flock", "spokenCamera_camera"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.set(true, forKey: $0) }
        let player = VoicePromptPlayer.shared
        player.updateContext(.init(navigating: true))
        let before = RoutingMetricsStore.shared.cameraEvents.count
        player.debugResolve = { _ in .init(samples: [0.1], reason: nil) }
        var spoken = Set<Int>()
        player.debugPlayback = { utterance, _ in
            spoken.formUnion(utterance.cameraOrdinals)
            Task { @MainActor in player.debugFinishCurrent() }
        }
        defer {
            player.stopAll(); player.debugResolve = nil; player.debugPlayback = nil; engine.setSpeechRoute(nil)
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for east in stride(from: 0.0, through: 600, by: 5) {
            engine.updateSpeechProgress(traveled: east, onRoute: true)
            let fix = CLLocation(coordinate: point(east, 0), altitude: 0, horizontalAccuracy: 3,
                verticalAccuracy: -1, course: 90, speed: 10, timestamp: Date())
            engine.updateCameraSpeech(location: fix, cameraStore: store, alertRadius: 60,
                inFieldOfView: false, alertsEnabled: true)
            try await Task.sleep(for: .milliseconds(1))
        }
        let requested = Set(RoutingMetricsStore.shared.cameraEvents.dropFirst(before).filter { $0.stage == "requested" }.compactMap(\.ordinal))
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(spoken.count, 2)
        XCTAssertEqual(engine.tripStats.totalCount, 2)
        XCTAssertEqual(engine.tripStats.alprCount, 1)
        XCTAssertEqual(engine.tripStats.otherCount, 1)
        XCTAssertEqual(engine.routeExposedCount, 2)
    }

    func testNormalScheduleAndAllCameraFormsAreReadyBeforeRequestIncludingAfterLock() async throws {
        let native = FastDriveSpeechEngine()
        let service = PhononSpeechService(engine: native, applicationActive: { true }, automaticWanted: { true })
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: NavigationVoice.storageKey)
        defaults.set("easton", forKey: NavigationVoice.storageKey)
        defer { service.endTrip(); if let old { defaults.set(old, forKey: NavigationVoice.storageKey) } else { defaults.removeObject(forKey: NavigationVoice.storageKey) } }
        service.warmUp()
        try await settle { service.loaded }
        service.beginTrip()
        let steps = [SpeechAheadPlanner.Step(banner: VisualInstructionContent(text: "Example Road", maneuverType: .turn,
            maneuverModifier: .right, roundaboutExitDegrees: nil, laneInfo: nil, exitNumbers: []), lanes: nil, distance: 3000, exit: nil)]
        let planned = SpeechAheadPlanner.utterances(steps: steps, units: .imperial, voice: .easton, lanesEnabled: false, lightsEnabled: false)
        service.plan(planned)
        let cameraPrompts = CameraPromptSelector.allKeys.map {
            VoiceUtterance(clips: [$0], priority: .camera, createdAt: 0, liveVoice: .easton)
        }
        try await settle { (planned + cameraPrompts).allSatisfy { service.debugCachedVariant(for: $0) != nil } }
        var schedule = GuidancePromptSchedule()
        for remaining in [2500.0, 1609, 804, 402, 60] {
            guard let crossing = schedule.update(step: 0, length: 3000, remaining: remaining, speed: 10) else { continue }
            var utterance: VoiceUtterance
            switch crossing {
            case .continueRoad(let key): utterance = .init(clips: [key], createdAt: 0, liveVoice: .easton)
            case .approach(_, let distance): utterance = .init(clips: GuidancePromptSelector.select(content: steps[0].banner, distance: distance, isApproach: true), createdAt: 0, liveVoice: .easton, roadName: "Example Road")
            case .final: utterance = .init(clips: ["turn_right"], createdAt: 0, liveVoice: .easton, roadName: "Example Road")
            }
            XCTAssertNotNil(service.debugCachedVariant(for: utterance), "Every schedule crossing must have matching pre-rendered text")
            utterance.createdAt = ProcessInfo.processInfo.systemUptime
            service.setForeground(false)
            let result = await service.resolve(utterance)
            XCTAssertNotNil(result.samples)
            XCTAssertNil(result.reason)
        }
        for var camera in cameraPrompts {
            camera.createdAt = ProcessInfo.processInfo.systemUptime
            let before = await native.renders
            let result = await service.resolve(camera)
            XCTAssertNotNil(result.samples)
            let after = await native.renders
            XCTAssertEqual(after, before, "No fixed camera sentence should render on demand")
        }
    }

    func testPredictionBypassesClearlyOverlongFullBeforeRendering() {
        let prompt = VoiceUtterance(clips: ["1mi.exit_right"], createdAt: 0, liveVoice: .easton,
            roadName: "Example International Transportation Boulevard", exitNumber: "12B")
        XCTAssertGreaterThan(SpeechLengthPrediction.preferred(PromptSpeech.variants(prompt)), 0)
        XCTAssertLessThan(SpeechLengthPrediction.seconds(["Turn right."]), 2)
    }

    func testPredictionMissQueuesShorterDuringRenderAheadBeforePlaybackAsks() async throws {
        let native = FastDriveSpeechEngine(overlongNamed: true)
        let service = PhononSpeechService(engine: native, applicationActive: { true }, automaticWanted: { true })
        defer { service.endTrip() }
        service.warmUp()
        try await settle { service.loaded }
        let prompt = VoiceUtterance(clips: ["500ft.turn_right"], createdAt: 0, liveVoice: .easton, roadName: "Oak Road")
        XCTAssertEqual(SpeechLengthPrediction.preferred(PromptSpeech.variants(prompt)), 0)
        service.plan([prompt])
        try await settle { service.debugCachedVariant(for: prompt) == .nameFree }
        let calls = await native.renders
        XCTAssertEqual(calls, 2, "Full-to-shorter fallback must happen during planning, not on demand")
    }

    func testLockWhileLoadedRenderIsRunningDoesNotCancelPrompt() async throws {
        let native = FastDriveSpeechEngine(delay: true)
        let service = PhononSpeechService(engine: native, applicationActive: { true }, automaticWanted: { true })
        defer { service.endTrip() }
        service.warmUp()
        try await settle { service.loaded }
        let prompt = VoiceUtterance(clips: ["turn_right"], createdAt: ProcessInfo.processInfo.systemUptime, liveVoice: .easton)
        let resolve = Task { await service.resolve(prompt) }
        try await settle { service.debugState(for: prompt).active }
        service.setForeground(false)
        let result = await resolve.value
        XCTAssertNotNil(result.samples)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.variant, .full)
    }

    func testOpeningOwnershipEndsOnlyOnActualPlayerCompletion() async throws {
        let player = VoicePromptPlayer()
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: VoiceSettings.masterKey)
        defaults.set(true, forKey: VoiceSettings.masterKey)
        defer { player.stopAll(); if let old { defaults.set(old, forKey: VoiceSettings.masterKey) } else { defaults.removeObject(forKey: VoiceSettings.masterKey) } }
        player.debugResolve = { _ in .init(samples: [0.1], reason: nil) }
        player.debugPlayback = { _, _ in }
        player.enqueue(.init(clips: ["depart"], createdAt: ProcessInfo.processInfo.systemUptime, liveVoice: .easton, isOpening: true))
        try await settle { player.openingPending }
        XCTAssertTrue(player.openingPending)
        player.debugFinishCurrent()
        XCTAssertFalse(player.openingPending)
    }

    private func settle(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 10
        while !predicate(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(predicate())
    }
}
#endif
