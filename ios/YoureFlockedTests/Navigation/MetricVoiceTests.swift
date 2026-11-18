import MapKit
import XCTest
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

final class MetricVoiceTests: XCTestCase {
    func testImperialDefaultAndMetricOptInHaveOnePreferenceKey() throws {
        let suite = "MetricVoiceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DistanceUnits.selected(defaults), .imperial)
        XCTAssertFalse(RoutePlanOptions.fromDefaults(defaults).useMetric)
        defaults.set(true, forKey: DistanceUnits.storageKey)
        XCTAssertEqual(DistanceUnits.selected(defaults), .metric)
        XCTAssertTrue(RoutePlanOptions.fromDefaults(defaults).useMetric)
        XCTAssertEqual(DistanceUnits.imperial.formatterUnits, .imperial)
        XCTAssertEqual(DistanceUnits.metric.formatterUnits, .metric)
    }

    func testMetricContinueAndCountdown() {
        var schedule = GuidancePromptSchedule()
        XCTAssertEqual(schedule.update(step: 0, length: 5000, remaining: 5000, speed: 20, units: .metric),
                       .continueRoad("continue_km.5_00"))
        for threshold in GuidancePromptSchedule.metricCountdown {
            XCTAssertEqual(schedule.update(step: 0, length: 5000, remaining: threshold.meters, speed: 10, units: .metric),
                           .approach(threshold.key, meters: threshold.meters))
            XCTAssertNil(schedule.update(step: 0, length: 5000, remaining: threshold.meters, speed: 10, units: .metric))
        }
        XCTAssertEqual(schedule.update(step: 0, length: 5000, remaining: 60, speed: 10, units: .metric), .final)
    }

    func testMetricShortStepAndJump() {
        var schedule = GuidancePromptSchedule()
        XCTAssertNil(schedule.update(step: 0, length: 180, remaining: 180, speed: 5, units: .metric))
        XCTAssertEqual(schedule.update(step: 0, length: 180, remaining: 100, speed: 5, units: .metric), .approach("100m", meters: 100))
        XCTAssertEqual(schedule.update(step: 0, length: 180, remaining: 30, speed: 5, units: .metric), .final)
        XCTAssertEqual(schedule.update(step: 1, length: 5000, remaining: 5000, speed: 20, units: .metric), .continueRoad("continue_km.5_00"))
        XCTAssertEqual(schedule.update(step: 1, length: 5000, remaining: 800, speed: 20, units: .metric), .approach("1km", meters: 1000))
        XCTAssertNil(schedule.update(step: 1, length: 5000, remaining: 800, speed: 20, units: .metric))
        schedule.reset()
        XCTAssertEqual(schedule.update(step: 1, length: 5000, remaining: 800, speed: 20, units: .metric), .approach("1km", meters: 1000))
    }

    func testMetricContinueRoundingAndGenericLimit() {
        XCTAssertNil(GuidancePromptSchedule.continueKey(meters: 249, units: .metric))
        XCTAssertEqual(GuidancePromptSchedule.continueKey(meters: 250, units: .metric), "continue_km.0_50")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(meters: 1200, units: .metric), "continue_km.1_00")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(meters: 1300, units: .metric), "continue_km.1_50")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(meters: 14_900, units: .metric), "continue_km.15_00")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(meters: 15_100, units: .metric), "continue_long")
        XCTAssertEqual(GuidancePromptSchedule.continueKeys.filter { $0.hasPrefix("continue_km.") }.count, 30)
    }

    func testUnitsChangeDoesNotReplayCrossedThresholdsOrContinue() {
        var schedule = GuidancePromptSchedule()
        _ = schedule.update(step: 0, length: 5000, remaining: 5000, speed: 20)
        _ = schedule.update(step: 0, length: 5000, remaining: 1600, speed: 20)
        XCTAssertNil(schedule.update(step: 0, length: 5000, remaining: 1500, speed: 20, units: .metric))
        XCTAssertEqual(schedule.update(step: 0, length: 5000, remaining: 1000, speed: 20, units: .metric), .approach("1km", meters: 1000))
    }

    func testMetricApproachesEveryActionAndSharedEnrichment() {
        let content = VisualInstructionContent(text: "Synthetic turn", maneuverType: .turn, maneuverModifier: .right,
                                               roundaboutExitDegrees: nil, laneInfo: nil, exitNumbers: [])
        for distance in GuidancePromptSelector.metricDistances {
            XCTAssertEqual(GuidancePromptSelector.select(content: content, distance: distance.meters, isApproach: true, units: .metric),
                           ["\(distance.key).turn_right"])
        }
        let lanes = [false, true].map { LaneInfo(active: $0, directions: [], activeDirection: nil) }
        XCTAssertEqual(GuidancePromptSelector.select(content: content, distance: 500, laneInfo: lanes,
                                                    signal: "at_next_light", isApproach: true, units: .metric),
                       ["at_next_light.turn_right", "lane_right"])
        XCTAssertEqual(GuidancePromptSelector.select(content: content, distance: 150, isApproach: false, units: .metric), ["turn_right"])
        let metricKeys = GuidancePromptSelector.allKeys.filter { $0.hasPrefix("2km.") || $0.hasPrefix("100m.") }
        XCTAssertEqual(metricKeys.count, GuidancePromptSelector.actions.count * 2)
    }

    func testCameraDistancesSwitchUnitsAndKeepUnitFreeForms() {
        let camera = SurveillanceCamera(osmID: 1, latitude: 0, longitude: 0, tags: ["surveillance:type": "ALPR", "brand": "Flock"])
        func select(_ distance: Double, units: DistanceUnits, direction: RelativeDirection = .ahead) -> String? {
            CameraPromptSelector.select(camera: camera, direction: direction, distance: distance, nearbyCount: 0,
                                        event: .entry, inFieldOfView: false, settings: VoiceSettings(),
                                        context: VoicePlaybackContext(navigating: true), units: units)
        }
        for meters in [200, 300, 400] { XCTAssertEqual(select(Double(meters), units: .metric), "cam.flock.\(meters)m") }
        XCTAssertEqual(select(199, units: .metric), "cam.flock.ahead")
        XCTAssertEqual(select(300, units: .imperial), "cam.flock.1000ft")
        for units in DistanceUnits.allCases { XCTAssertEqual(select(400, units: units, direction: .right), "cam.flock.right") }
    }

    func testMetricPreviewUsesMetricDistanceForRequestedVoice() {
        for voice in PromptVoice.allCases {
            let preview = VoiceUtterance.preview(voice: voice, now: 0, units: .metric)
            XCTAssertEqual(preview.voice, voice)
            XCTAssertEqual(preview.clips, ["200m.turn_right", "lane_right", "cam.flock.ahead"])
        }
    }
}
