#if DEBUG
import CoreLocation
import XCTest
@testable import YoureFlocked

@MainActor
final class AlertFilterInteractionTests: XCTestCase {
    private func point(_ east: Double, _ north: Double = 0) -> CLLocationCoordinate2D {
        .init(latitude: north / 111_320, longitude: east / 111_320)
    }

    private func camera(_ id: Int64 = 1) -> SurveillanceCamera {
        let p = point(100, 5)
        return SurveillanceCamera(osmID: id, latitude: p.latitude, longitude: p.longitude,
            tags: ["surveillance:type": "camera", "direction": "270"])
    }

    private func fix(_ east: Double, time: Double = 0) -> CLLocation {
        CLLocation(coordinate: point(east), altitude: 0, horizontalAccuracy: 3, verticalAccuracy: -1,
            course: 90, speed: 10, timestamp: Date(timeIntervalSince1970: 1000 + time))
    }

    private func store(_ camera: SurveillanceCamera) -> CameraStore {
        let result = CameraStore()
        result.cameras = [camera]
        result.lastFetchBounds = BoundingBox(south: -0.01, west: -0.01, north: 0.01, east: 0.01)
        return result
    }

    private func withSpeech(_ test: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = [VoiceSettings.masterKey, VoiceSettings.camerasKey, VoiceSettings.outsideNavigationKey,
                    CameraVoiceType.camera.storageKey, NavigationVoice.storageKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys.dropLast() { defaults.set(true, forKey: key) }
        defaults.set("easton", forKey: NavigationVoice.storageKey)
        let player = VoicePromptPlayer.shared
        player.stopAll()
        player.debugResolve = { _ in .init(samples: [0.1], reason: nil) }
        defer {
            player.stopAll(); player.debugResolve = nil; player.debugPlayback = nil
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await test()
    }

    func testVisibleButFilteredCameraIsNeitherSpokenNorCountedOrExposed() async throws {
        try await withSpeech {
            let camera = camera()
            let store = store(camera)
            let path = [point(0), point(200)]
            let filter = CameraTypeFilter(showGeneric: false)
            XCTAssertEqual(CameraObservability.RouteExposure.build(path: path, cameras: store.cameras).exposedIDs, [camera.id])
            XCTAssertTrue(CameraObservability.RouteExposure.build(path: path, cameras: store.cameras, filter: filter).exposedIDs.isEmpty)
            let engine = ProximityAlertEngine()
            engine.voiceContext = { .init(navigating: true) }
            VoicePromptPlayer.shared.updateContext(.init(navigating: true))
            var spoken = 0
            VoicePromptPlayer.shared.debugPlayback = { _, _ in spoken += 1 }
            engine.setSpeechRoute(path, cameras: store.cameras, filter: filter)
            await engine.waitForExposure()
            engine.updateCameraSpeech(location: fix(75), cameraStore: store, alertRadius: 200,
                inFieldOfView: false, alertsEnabled: true, filter: filter)
            engine.updateSpeechProgress(traveled: 120, onRoute: true)
            await Task.yield()
            XCTAssertEqual(engine.routeExposedCount, 0)
            XCTAssertEqual(engine.tripStats.totalCount, 0)
            XCTAssertEqual(engine.navigationStats.totalCount, 0)
            XCTAssertEqual(spoken, 0)
            XCTAssertEqual(store.cameras.count, 1, "Routing input remains unfiltered")
            engine.setSpeechRoute(nil)
        }
    }

    func testFilterChangeInvalidatesPreviouslyBuiltExposureBeforeNextProgress() async throws {
        let camera = camera()
        let store = store(camera)
        let engine = ProximityAlertEngine()
        engine.voiceContext = { .init(navigating: true) }
        engine.setSpeechRoute([point(0), point(200)], cameras: store.cameras, filter: .all)
        await engine.waitForExposure()
        XCTAssertEqual(engine.routeExposedCount, 1)
        engine.updateCameraSpeech(location: fix(50), cameraStore: store, alertRadius: 200,
            inFieldOfView: false, alertsEnabled: true, filter: CameraTypeFilter(showGeneric: false))
        engine.updateSpeechProgress(traveled: 120, onRoute: true)
        await engine.waitForExposure()
        XCTAssertEqual(engine.routeExposedCount, 0)
        XCTAssertEqual(engine.navigationStats.totalCount, 0)
        engine.setSpeechRoute(nil)
    }

    func testMutedNotificationLeavesBannerSpeechAndNavigationCountUnchanged() async throws {
        try await withSpeech {
            let suite = "AlertFilterInteractionTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = NotificationManager(defaults: defaults)
            manager.isAuthorized = true
            let camera = camera()
            manager.handleAction("MUTE_CAMERA", cameraID: camera.id)
            XCTAssertFalse(manager.admitProximityAlert(for: camera))
            let store = store(camera)
            let engine = ProximityAlertEngine()
            engine.voiceContext = { .init(navigating: true) }
            let player = VoicePromptPlayer.shared
            player.updateContext(.init(navigating: true))
            var spoken = 0
            player.debugPlayback = { _, _ in spoken += 1 }
            engine.setSpeechRoute([point(0), point(200)], cameras: store.cameras, filter: .all)
            await engine.waitForExposure()
            engine.updateSpeechProgress(traveled: 75, onRoute: true)
            engine.handleLocationUpdate(location: fix(75), heading: nil, cameraStore: store,
                notificationManager: manager, liveActivityManager: nil, alertRadius: 200,
                alertMode: .nearCamera, enableHaptics: false, filter: .all)
            for _ in 0..<20 where spoken == 0 { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertEqual(spoken, 1)
            XCTAssertEqual(engine.activeAlert?.cameraID, camera.id)
            XCTAssertEqual(engine.tripStats.otherCount, 1)
            XCTAssertEqual(engine.navigationStats.otherCount, 1)
            XCTAssertFalse(manager.admitProximityAlert(for: camera), "Speech/counts must not clear the notification mute")
            engine.setSpeechRoute(nil)
        }
    }

    func testNonNavigationTrackCountAlsoHonoursFilter() {
        let camera = camera()
        let store = store(camera)
        for show in [false, true] {
            let engine = ProximityAlertEngine()
            let filter = CameraTypeFilter(showGeneric: show)
            for (index, east) in [65.0, 75.0, 85.0].enumerated() {
                engine.updateCameraSpeech(location: fix(east, time: Double(index)), cameraStore: store,
                    alertRadius: 200, inFieldOfView: false, alertsEnabled: false, filter: filter)
            }
            XCTAssertEqual(engine.tripStats.totalCount, show ? 1 : 0)
        }
    }

    func testFilterChangeCancelsInflightExposureBuild() async {
        let camera = camera()
        let store = store(camera)
        let engine = ProximityAlertEngine()
        engine.voiceContext = { .init(navigating: true) }
        engine.setSpeechRoute([point(0), point(200)], cameras: store.cameras, filter: .all)
        // Change settings before the detached build can publish its result.
        engine.updateCameraSpeech(location: fix(50), cameraStore: store, alertRadius: 200,
            inFieldOfView: false, alertsEnabled: true, filter: CameraTypeFilter(showGeneric: false))
        await engine.waitForExposure()
        engine.updateSpeechProgress(traveled: 120, onRoute: true)
        XCTAssertEqual(engine.routeExposedCount, 0)
        XCTAssertEqual(engine.tripStats.totalCount, 0)
        engine.setSpeechRoute(nil)
    }
}
#endif
