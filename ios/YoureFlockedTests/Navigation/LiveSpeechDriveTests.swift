#if DEBUG
import CoreLocation
import XCTest
import UIKit
@testable import YoureFlocked

@MainActor
final class LiveSpeechDriveTests: XCTestCase {
    override func tearDown() async throws {
        VoicePromptPlayer.shared.stopAll()
        PhononSpeechService.shared.endTrip()
        // Both the synthetic controller and test host disable OS requests.
        // Drain anything pre-existing before the test process can terminate.
        await Task.yield()
        await LiveActivityManager.endAllActivities()
        try await super.tearDown()
    }
    func testSyntheticSimulatedDriveColdOpeningNeverUsesRecordings() async throws {
        let defaults = UserDefaults.standard
        let keys = [NavigationVoice.storageKey, VoiceSettings.masterKey, VoiceSettings.directionsKey,
                    DebugDriveSimulationSettings.speedKey, DebugDriveSimulationSettings.timeKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            PhononSpeechService.shared.forceFailure = false
            PhononSpeechService.shared.endTrip()
            VoicePromptPlayer.shared.stopAll()
        }
        defaults.set("easton", forKey: NavigationVoice.storageKey)
        defaults.set(true, forKey: VoiceSettings.masterKey)
        defaults.set(true, forKey: VoiceSettings.directionsKey)
        defaults.set(35, forKey: DebugDriveSimulationSettings.speedKey)
        defaults.set(2, forKey: DebugDriveSimulationSettings.timeKey)
        PhononSpeechService.shared.setForeground(true)
        try await PhononSpeechService.shared.unloadForTesting()

        // Null-island geometry only; no tile pack, external geocoder or real route.
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 0, longitude: 0.003)
        let c = CLLocationCoordinate2D(latitude: 0.003, longitude: 0.003)
        let steps: [OSRMFixture.Step] = [
            .init(geometry: [a, b], maneuverType: "turn", modifier: "right", instruction: "Main Street", distanceMeters: 334),
            .init(geometry: [b, c], maneuverType: "turn", modifier: "left", instruction: "Oak Avenue", distanceMeters: 334),
            .init(geometry: [c, c], maneuverType: "arrive", modifier: nil, instruction: "You have arrived.", distanceMeters: 0),
        ]
        let response = try OSRMFixture.response(steps: steps)
        let plan = RoutePlan(route: ValhallaRoute(coordinates: [a, b, c], distanceKm: 0.668, timeSeconds: 42, maneuvers: []),
                             avoidedCount: 0, totalCount: 0, requestJSON: Data("{}".utf8), candidateIndex: 0)
        let location = LocationManager()
        let store = CameraStore()
        let proximity = ProximityAlertEngine()
        let controller = NavigationSessionController(locationManager: location, cameraStore: store,
            proximityEngine: proximity, liveActivityManager: LiveActivityManager(activityRequestsEnabled: false), routingService: ValhallaRoutingService())
        controller.simulateDrive = true
        controller.debugNavigationResponse = response
        let openingBefore = VoicePlaybackDiagnostics.openingCount
        let recordedBefore = VoicePlaybackDiagnostics.recordedCount
        await controller.start(plan: plan, destination: .init(name: "Example destination", coordinate: c), routeCameras: [])
        defer { controller.stop() }
        XCTAssertNil(controller.startError)
        let openingDeadline = ProcessInfo.processInfo.systemUptime + VoiceRenderPolicy.openingDeadline + 0.5
        while VoicePlaybackDiagnostics.openingCount == openingBefore, ProcessInfo.processInfo.systemUptime < openingDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(VoicePlaybackDiagnostics.openingCount, openingBefore)
        XCTAssertEqual(VoicePlaybackDiagnostics.recordedCount, recordedBefore)
        let stats = VoicePromptPlayer.shared.speechStats()
        let detail = XCTAttachment(string: "Live trip requested \(stats.requested), spoke \(stats.spoken), skips \(stats.skipped)")
        detail.lifetime = .keepAlways
        add(detail)
        let attachment = XCTAttachment(string: "Cold synthetic drive: selected live opening reached AVAudioPlayerNode; no recordings. No text exported.")
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
