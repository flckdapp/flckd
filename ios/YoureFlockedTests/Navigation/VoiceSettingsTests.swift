import XCTest
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

final class VoiceSettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "VoiceSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testPermissionMatrix() {
        for bits in 0..<128 {
            let settings = VoiceSettings(
                master: bits & 1 != 0, directions: bits & 2 != 0,
                trafficLights: bits & 8 != 0, rerouting: bits & 16 != 0,
                cameras: bits & 32 != 0, outsideNavigation: bits & 64 != 0
            )
            for navigating in [false, true] {
                for muted in [false, true] {
                    let context = VoicePlaybackContext(navigating: navigating, tripMuted: muted)
                    let automatic = settings.master && !muted
                    XCTAssertEqual(settings.allows(.directions, context: context), automatic && settings.directions)
                    XCTAssertEqual(settings.allows(.lane, context: context), automatic && settings.directions)
                    XCTAssertEqual(settings.allows(.trafficLight, context: context), automatic && settings.directions && settings.trafficLights)
                    XCTAssertEqual(settings.allows(.rerouting, context: context), automatic && settings.rerouting)
                    for type in CameraVoiceType.allCases {
                        XCTAssertEqual(settings.allows(.camera(type), context: context),
                                       automatic && settings.cameras && (navigating || settings.outsideNavigation))
                    }
                    XCTAssertEqual(settings.allows(.preview, context: context), !navigating)
                }
            }
        }
    }

    func testCameraTypesAndDirectionsAreIndependent() {
        var settings = VoiceSettings(directions: false)
        let context = VoicePlaybackContext(navigating: true)
        for type in CameraVoiceType.allCases {
            XCTAssertTrue(settings.allows(.camera(type), context: context))
            settings.cameraTypes.remove(type)
            XCTAssertFalse(settings.allows(.camera(type), context: context))
        }
        XCTAssertTrue(settings.allows(.rerouting, context: context))
    }

    func testDefaultsKeepExistingDirectionsChoice() throws {
        try withDefaults { defaults in
            XCTAssertEqual(VoiceSettings.fromDefaults(defaults), VoiceSettings())
            defaults.set(false, forKey: VoiceSettings.directionsKey)
            VoiceSettings.migrate(defaults)
            let settings = VoiceSettings.fromDefaults(defaults)
            XCTAssertFalse(settings.directions)
            XCTAssertTrue(settings.master)
            XCTAssertTrue(settings.cameras)
            for type in CameraVoiceType.allCases {
                defaults.set(false, forKey: type.storageKey)
                XCTAssertFalse(VoiceSettings.fromDefaults(defaults).cameraTypes.contains(type))
            }
        }
    }

    func testLegacyCameraModeMigration() throws {
        for mode in ["off", "navigating", "always", "unexpected"] {
            try withDefaults { defaults in
                defaults.set(mode, forKey: VoiceSettings.legacyCameraModeKey)
                // The read path agrees with the migration, even before launch.
                let before = VoiceSettings.fromDefaults(defaults)
                VoiceSettings.migrate(defaults)
                let after = VoiceSettings.fromDefaults(defaults)
                XCTAssertEqual(before, after)
                XCTAssertEqual(after.cameras, mode != "off")
                XCTAssertEqual(after.outsideNavigation, mode == "always")
                defaults.set(!after.cameras, forKey: VoiceSettings.camerasKey)
                defaults.set(!after.outsideNavigation, forKey: VoiceSettings.outsideNavigationKey)
                VoiceSettings.migrate(defaults)
                XCTAssertEqual(VoiceSettings.fromDefaults(defaults).cameras, !after.cameras)
                XCTAssertEqual(VoiceSettings.fromDefaults(defaults).outsideNavigation, !after.outsideNavigation)
            }
        }
    }

    func testMigrationPreservesPartiallyWrittenNewPreferences() throws {
        try withDefaults { defaults in
            defaults.set("always", forKey: VoiceSettings.legacyCameraModeKey)
            defaults.set(false, forKey: VoiceSettings.camerasKey)
            VoiceSettings.migrate(defaults)
            XCTAssertFalse(VoiceSettings.fromDefaults(defaults).cameras)
            XCTAssertTrue(VoiceSettings.fromDefaults(defaults).outsideNavigation)
        }
    }

    func testSelectorDisablesLanesAndUsesPlainTurnWithoutSignals() {
        let content = VisualInstructionContent(text: "Synthetic turn", maneuverType: .turn, maneuverModifier: .right,
                                               roundaboutExitDegrees: nil, laneInfo: nil, exitNumbers: [])
        let lanes = [false, true].map { LaneInfo(active: $0, directions: [], activeDirection: nil) }
        for distance in [20.0, 300.0] {
            for useLanes in [false, true] {
                for useLights in [false, true] {
                    let clips = GuidancePromptSelector.select(
                        content: content, distance: distance, laneInfo: lanes,
                        signal: distance < 150 ? "at_light" : "at_next_light",
                        lanesEnabled: useLanes, trafficLightsEnabled: useLights
                    )
                    let action = useLights ? (distance < 150 ? "at_light.turn_right" : "at_next_light.turn_right")
                        : (distance < 150 ? "turn_right" : "1000ft.turn_right")
                    XCTAssertEqual(clips, useLanes && distance >= 150 ? [action, "lane_right"] : [action])
                }
            }
        }
    }

    func testQueuedPromptsAreRecheckedAfterSettingsChanges() {
        let context = VoicePlaybackContext(navigating: true)
        let direction = VoiceUtterance(clips: ["turn_right"], createdAt: 0)
        let lane = VoiceUtterance(clips: ["1000ft.turn_right", "lane_right"], createdAt: 0)
        let light = VoiceUtterance(clips: ["at_light.turn_right"], createdAt: 0)
        let camera = VoiceUtterance(clips: ["cam.flock.ahead"], priority: .camera, kind: .camera(.flock), createdAt: 0)
        let reroute = VoiceUtterance(clips: ["rerouting"], kind: .rerouting, createdAt: 0)
        var queue = VoicePromptQueue()
        for prompt in [direction, lane, light, camera, reroute] { queue.enqueue(prompt) }
        queue.removeDisallowed(settings: VoiceSettings(directions: false), context: context)
        XCTAssertEqual(queue.pending, [camera, reroute])
        queue.removeDisallowed(settings: VoiceSettings(master: false), context: context)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertTrue(VoiceSettings().allows(lane, context: context))
        XCTAssertFalse(VoiceSettings(directions: false).allows(lane, context: context))
        XCTAssertFalse(VoiceSettings(trafficLights: false).allows(light, context: context))
        XCTAssertFalse(VoiceSettings(rerouting: false).allows(reroute, context: context))
        XCTAssertFalse(VoiceSettings().allows(camera, context: VoicePlaybackContext(navigating: true, tripMuted: true)))
    }

    func testPreviewUsesRequestedVoiceAndReplacesPendingPreview() {
        var queue = VoicePromptQueue()
        for voice in PromptVoice.allCases {
            let preview = VoiceUtterance.preview(voice: voice, now: 0)
            XCTAssertEqual(preview.voice, voice)
            XCTAssertEqual(preview.clips, ["500ft.turn_right", "lane_right", "cam.flock.ahead"])
            XCTAssertTrue(VoiceSettings(master: false).allows(preview, context: VoicePlaybackContext()))
            XCTAssertFalse(VoiceSettings().allows(preview, context: VoicePlaybackContext(navigating: true)))
            queue.enqueue(preview)
            XCTAssertEqual(queue.pending, [preview])
        }
        queue.removeDisallowed(settings: VoiceSettings(), context: VoicePlaybackContext(navigating: true))
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testTripMuteDoesNotWritePersistentPreferences() throws {
        try withDefaults { defaults in
            VoiceSettings.migrate(defaults)
            let original = defaults.dictionaryRepresentation()
            let settings = VoiceSettings.fromDefaults(defaults)
            let muted = VoicePlaybackContext(navigating: true, tripMuted: true)
            for kind: VoicePromptKind in [.directions, .lane, .trafficLight, .rerouting, .camera(.flock)] {
                XCTAssertFalse(settings.allows(kind, context: muted))
            }
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, original as NSDictionary)
            XCTAssertTrue(settings.allows(.directions, context: VoicePlaybackContext(navigating: true)))
        }
    }
}
