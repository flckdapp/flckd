import AVFoundation
import CoreLocation
import XCTest
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

final class VoicePromptTests: XCTestCase {
    private func content(
        _ type: FerrostarCoreFFI.ManeuverType?, _ modifier: ManeuverModifier? = .straight,
        degrees: UInt16? = nil
    ) -> VisualInstructionContent {
        VisualInstructionContent(text: "Synthetic instruction", maneuverType: type, maneuverModifier: modifier,
                                 roundaboutExitDegrees: degrees, laneInfo: nil, exitNumbers: [])
    }

    func testManeuverFamilies() {
        let cases: [(FerrostarCoreFFI.ManeuverType, ManeuverModifier, String)] = [
            (.turn, .left, "turn_left"), (.turn, .right, "turn_right"),
            (.turn, .slightLeft, "slight_left"), (.turn, .slightRight, "slight_right"),
            (.turn, .sharpLeft, "sharp_left"), (.turn, .sharpRight, "sharp_right"),
            (.turn, .uTurn, "uturn"), (.turn, .straight, "continue"),
            (.newName, .straight, "continue"), (.continue, .slightLeft, "slight_left"),
            (.fork, .left, "keep_left"), (.fork, .right, "keep_right"), (.fork, .straight, "keep_straight"),
            (.onRamp, .left, "ramp_left"), (.onRamp, .right, "ramp_right"),
            (.offRamp, .left, "exit_left"), (.offRamp, .right, "exit_right"),
            (.merge, .left, "merge_left"), (.merge, .right, "merge_right"),
            (.endOfRoad, .left, "end_left"), (.endOfRoad, .right, "end_right"),
            (.depart, .straight, "depart"), (.arrive, .straight, "arrive"),
            (.arrive, .left, "arrive_left"), (.arrive, .right, "arrive_right"),
        ]
        for (type, modifier, expected) in cases {
            XCTAssertEqual(GuidancePromptSelector.select(content: content(type, modifier), distance: 0), [expected])
        }
    }

    func testRoundaboutExitsAreNumbersNotAngles() {
        for type: FerrostarCoreFFI.ManeuverType in [.roundabout, .rotary, .roundaboutTurn] {
            for exit in UInt8(1)...4 {
                XCTAssertEqual(GuidancePromptSelector.select(content: content(type, degrees: 180), distance: 0,
                                                            roundaboutExit: exit), ["roundabout_\(exit)"])
            }
            XCTAssertEqual(GuidancePromptSelector.select(content: content(type, degrees: 180), distance: 0), [])
            XCTAssertEqual(GuidancePromptSelector.select(content: content(type), distance: 0, roundaboutExit: 5),
                           type == .roundaboutTurn ? ["continue"] : [])
        }
    }

    func testUnsupportedInstructionsUseFallback() {
        for type: FerrostarCoreFFI.ManeuverType? in [nil, .notification, .exitRoundabout, .exitRotary] {
            XCTAssertEqual(GuidancePromptSelector.select(content: content(type), distance: 0), [])
        }
        XCTAssertEqual(GuidancePromptSelector.select(content: nil, distance: 0), [])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.merge), distance: 0), [])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.arrive), distance: 500), [])
    }

    func testDistanceBucketsAndFinalThreshold() {
        for distance in GuidancePromptSelector.distances {
            XCTAssertEqual(GuidancePromptSelector.select(content: content(.turn, .right), distance: distance.meters),
                           ["\(distance.key).turn_right"])
        }
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.turn, .left), distance: 149), ["turn_left"])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.turn, .left), distance: 150), ["500ft.turn_left"])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.continue), distance: 6000, longContinue: true), ["continue_long"])
        XCTAssertEqual(GuidancePromptSelector.nearestDistance(230), "1000ft")
        XCTAssertTrue(GuidancePromptSelector.isContinueReminder(text: "Continue for a while", distance: 569))
        XCTAssertFalse(GuidancePromptSelector.isContinueReminder(text: "Turn left", distance: 5000))
        XCTAssertFalse(GuidancePromptSelector.isContinueReminder(text: "Continue straight", distance: 100))
    }

    func testLaneGroupsAndApproachOnly() {
        func lanes(_ flags: [Bool]) -> [LaneInfo] {
            flags.map { LaneInfo(active: $0, directions: [], activeDirection: nil) }
        }
        let cases: [([Bool], String?)] = [
            ([true, false, false], "lane_left"), ([true, true, false], "lane_left2"),
            ([false, false, true], "lane_right"), ([false, true, true], "lane_right2"),
            ([false, true, false], "lane_middle"), ([true, false, true], nil),
            ([false, false, false], nil), ([true, true, true], nil),
            ([false, true, false, false], nil), ([true], nil), ([], nil),
        ]
        for (flags, expected) in cases { XCTAssertEqual(GuidancePromptSelector.lane(lanes(flags)), expected) }
        let info = lanes([false, false, true])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.turn, .right), distance: 300, laneInfo: info),
                       ["1000ft.turn_right", "lane_right"])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.turn, .right), distance: 20, laneInfo: info), ["turn_right"])
    }

    func testSignalsOnlyReplaceSupportedActions() {
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.turn, .left), distance: 20, signal: "at_light"), ["at_light.turn_left"])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.turn, .right), distance: 400, signal: "at_second_light"), ["at_second_light.turn_right"])
        XCTAssertEqual(GuidancePromptSelector.select(content: content(.offRamp, .right), distance: 400, signal: "at_next_light"), ["quarter_mi.exit_right"])
    }

    func testSignalMappingWithSyntheticGeometry() {
        let shape = (0...4).map { GeographicCoordinate(lat: 0, lng: Double($0) * 0.001) }
        let distance = RouteSignals.cumulative(shape)
        let signals = RouteSignals(signals: [1, 2, 4].map {
            RouteSignals.Signal(coordinate: shape[$0], distanceAlongRoute: distance[$0])
        })
        XCTAssertEqual(signals.prefix(maneuver: shape[2], targetDistance: distance[2], userDistance: 0, approach: true), "at_second_light")
        XCTAssertEqual(signals.prefix(maneuver: shape[2], targetDistance: distance[2], userDistance: distance[1] + 10, approach: true), "at_next_light")
        XCTAssertEqual(signals.prefix(maneuver: shape[2], targetDistance: distance[2], userDistance: 0, approach: false), "at_light")
        XCTAssertNil(signals.prefix(maneuver: shape[3], targetDistance: distance[3], userDistance: 0, approach: false))
        XCTAssertNil(signals.prefix(maneuver: shape[4], targetDistance: distance[4], userDistance: 0, approach: true))
        // Same point revisited in a loop must not use its earlier signal.
        XCTAssertNil(signals.prefix(maneuver: shape[2], targetDistance: distance[2] + 1000, userDistance: 0, approach: false))
    }

    func testTraceSignalParserUsesReturnedShapeIndices() throws {
        let shape = [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                     CLLocationCoordinate2D(latitude: 0, longitude: 0.001),
                     CLLocationCoordinate2D(latitude: 0, longitude: 0.002)]
        let object: [String: Any] = ["shape": PolylineEncoder.encode(shape), "edges": [
            ["end_shape_index": 1, "end_node": ["traffic_signal": true]],
            ["end_shape_index": 1, "end_node": ["traffic_signal": true]],
            ["end_shape_index": 2, "end_node": ["traffic_signal": false]],
            ["end_shape_index": 100, "end_node": ["traffic_signal": true]],
        ]]
        let parsed = try RouteSignals.parse(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(parsed.signals.count, 1)
        XCTAssertEqual(parsed.signals.first?.coordinate.lng, 0.001)
        XCTAssertThrowsError(try RouteSignals.parse(Data("{}".utf8)))
    }

    func testParsedBannerDescribesTheNextStepNotCurrentManeuver() throws {
        let shape = [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                     CLLocationCoordinate2D(latitude: 0, longitude: 0.001),
                     CLLocationCoordinate2D(latitude: 0.001, longitude: 0.001)]
        let data = try OSRMFixture.response(steps: [
            .init(geometry: Array(shape.prefix(2)), maneuverType: "depart", modifier: nil,
                  instruction: "Head forward", distanceMeters: 111),
            .init(geometry: Array(shape.suffix(2)), maneuverType: "roundabout", modifier: "right",
                  instruction: "Take the second exit", distanceMeters: 111),
        ])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var routes = try XCTUnwrap(json["routes"] as? [[String: Any]])
        var legs = try XCTUnwrap(routes[0]["legs"] as? [[String: Any]])
        var steps = try XCTUnwrap(legs[0]["steps"] as? [[String: Any]])
        // Real Valhalla field relationship, with synthetic geometry/text only.
        steps[0]["bannerInstructions"] = [["distanceAlongGeometry": 111,
                                           "primary": ["text": "Take the second exit", "type": "roundabout", "components": []]]]
        var maneuver = try XCTUnwrap(steps[1]["maneuver"] as? [String: Any])
        maneuver["exit"] = 2
        steps[1]["maneuver"] = maneuver
        legs[0]["steps"] = steps
        routes[0]["legs"] = legs
        json["routes"] = routes
        let parsed = try XCTUnwrap(FlckdRouteProvider.routes(fromOSRM: JSONSerialization.data(withJSONObject: json)).first)
        XCTAssertEqual(parsed.steps[0].visualInstructions.first?.primaryContent.maneuverType, .roundabout)
        XCTAssertNil(parsed.steps[0].roundaboutExitNumber)
        XCTAssertEqual(parsed.steps[1].roundaboutExitNumber, 2)
        XCTAssertEqual(GuidancePromptSelector.select(content: parsed.steps[0].visualInstructions.first?.primaryContent,
                                                    distance: 0, roundaboutExit: parsed.steps[1].roundaboutExitNumber), ["roundabout_2"])
    }

    private func camera(_ type: SurveillanceType = .alpr, tags: [String: String] = [:]) -> SurveillanceCamera {
        SurveillanceCamera(osmID: 1, latitude: 0, longitude: 0,
                           tags: tags.merging(["surveillance:type": type.rawValue]) { _, new in new })
    }

    func testFlockManufacturerAndBrandVariants() {
        for tag in ["manufacturer", "brand"] {
            for spelling in ["Flock", "Flock Safety", "FLOCK SAFETY", "flock"] {
                XCTAssertEqual(CameraPromptSelector.type(for: camera(tags: [tag: spelling])), .flock)
            }
        }
        XCTAssertEqual(CameraPromptSelector.type(for: camera(tags: ["manufacturer": "Other", "brand": "Flock"])), .flock)
        XCTAssertEqual(CameraPromptSelector.type(for: camera()), .camera)
        XCTAssertEqual(CameraPromptSelector.type(for: camera(.camera, tags: ["brand": "Flock"])), .camera)
        XCTAssertEqual(CameraPromptSelector.type(for: camera(.speedCamera)), .speed)
        XCTAssertEqual(CameraPromptSelector.type(for: camera(.gunshotDetector)), .gunshot)
        XCTAssertNil(CameraPromptSelector.type(for: camera(.guard_)))
        XCTAssertNil(CameraPromptSelector.type(for: camera(.unknown)))
    }

    func testCameraDirectionDistanceCountsAndEscalation() {
        func select(_ direction: RelativeDirection, distance: Double = 100, count: Int = 0,
                    event: CameraPromptSelector.Event = .entry, fov: Bool = false) -> String? {
            CameraPromptSelector.select(camera: camera(tags: ["brand": "Flock Safety"]), direction: direction,
                                        distance: distance, nearbyCount: count, event: event, inFieldOfView: fov,
                                        settings: VoiceSettings(), context: VoicePlaybackContext(navigating: true))
        }
        for direction in [RelativeDirection.ahead, .right, .left, .nearby] {
            XCTAssertEqual(select(direction), "cam.flock.\(direction.rawValue.lowercased())")
        }
        XCTAssertNil(select(.behind))
        XCTAssertEqual(select(.ahead, distance: 300), "cam.flock.1000ft")
        XCTAssertEqual(select(.ahead, distance: 450), "cam.flock.quarter_mi")
        XCTAssertEqual(select(.ahead, count: 1), "cam.cameras_ahead_2")
        XCTAssertEqual(select(.ahead, count: 2), "cam.cameras_ahead_3")
        XCTAssertEqual(select(.ahead, count: 3), "cam.cameras_ahead_many")
        XCTAssertEqual(select(.nearby, count: 1), "cam.cameras_ahead_2")
        XCTAssertEqual(select(.behind, event: .passing), "cam.flock.passing")
        XCTAssertEqual(select(.ahead, event: .passing, fov: true), "cam.flock.passing")
        XCTAssertEqual(select(.behind, fov: true), "cam.flock.in_view")
    }

    func testUtterancePriorityGroupingAndStaleness() {
        var queue = VoicePromptQueue()
        let camera = VoiceUtterance(clips: ["cam.camera.ahead"], priority: .camera, createdAt: 0)
        let guidance = VoiceUtterance(clips: ["1000ft.turn_left", "lane_left"], createdAt: 4)
        queue.enqueue(camera)
        queue.enqueue(guidance)
        XCTAssertEqual(queue.next(now: 4), guidance)
        XCTAssertEqual(queue.next(now: 5), camera)
        queue.enqueue(camera)
        XCTAssertNil(queue.next(now: 5.001))
        queue.enqueue(guidance)
        queue.remove(.camera)
        XCTAssertEqual(queue.next(now: 10), guidance)
        XCTAssertNil(queue.next(now: 10))
    }

    func testTimelineGapsAndPCMJoinsByMeasurement() {
        let rate = 44_100.0
        let clips = [[Float](repeating: 0.5, count: 1000), [Float](repeating: 0.5, count: 2000)]
        let timeline = VoiceTimeline.segments(lengths: clips.map(\.count), sampleRate: rate)
        XCTAssertEqual(timeline[1].startFrame - timeline[0].frameCount, 15_435)
        XCTAssertEqual(VoiceTimeline.segments(lengths: [1000, 2000], sampleRate: rate,
                                             gap: VoiceTimeline.intraSentenceGap)[1].startFrame, 6292)
        let pcm = VoicePCM.compose(clips, sampleRate: rate)
        XCTAssertEqual(pcm.count, 18_435)
        XCTAssertTrue(pcm[1000..<16_435].allSatisfy { $0 == 0 })
        XCTAssertEqual(pcm[0], 0)
        XCTAssertEqual(pcm[999], 0)
        XCTAssertEqual(pcm[16_435], 0)
        XCTAssertEqual(pcm[353], 0.5)
        XCTAssertEqual(VoicePCM.trimmed([0, 0, 0.5, 0.4, 0, 0]), [0.5, 0.4])
        print("Measured PCM join: 15435 silent frames / 44100 Hz = 350 ms; intra-sentence = 5292 frames = 120 ms")
    }

    func testAudioEngineOfflineRenderPreservesMeasuredGap() throws {
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let samples = VoicePCM.compose([[Float](repeating: 0.5, count: 1000),
                                        [Float](repeating: 0.5, count: 2000)], sampleRate: rate)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        input.frameLength = input.frameCapacity
        let channel = try XCTUnwrap(input.floatChannelData?[0])
        for index in samples.indices { channel[index] = samples[index] }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        node.scheduleBuffer(input)
        try engine.start()
        node.play()
        defer { node.stop(); engine.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var rendered: [Float] = []
        for _ in 0..<40 where rendered.count < samples.count {
            let frames = AVAudioFrameCount(min(1024, samples.count - rendered.count))
            let status = try engine.renderOffline(frames, to: output)
            if status == .success {
                let outputChannel = try XCTUnwrap(output.floatChannelData?[0])
                rendered += Array(UnsafeBufferPointer(start: outputChannel, count: Int(output.frameLength)))
            }
        }
        XCTAssertEqual(rendered.count, samples.count)
        guard rendered.count == samples.count else { return }
        XCTAssertTrue(rendered[1000..<16_435].allSatisfy { abs($0) < 0.00001 })
        XCTAssertGreaterThan(abs(rendered[500]), 0.1)
        XCTAssertGreaterThan(abs(rendered[16_935]), 0.1)
        print("AVAudioEngine offline render: 15435 silent join frames at 44100 Hz (350 ms), audible PCM on both sides")
    }

    func testEverySelectableKeyExistsInBothBundledVoices() throws {
        let keys = GuidancePromptSelector.allKeys.union(CameraPromptSelector.allKeys)
        for voice in PromptVoice.allCases {
            for key in keys { XCTAssertNotNil(voice.url(for: key), "\(voice)/\(key)") }
        }
        XCTAssertGreaterThan(keys.count, 200)
    }

    func testVoicesRemainDistinctFolders() throws {
        let male = try XCTUnwrap(PromptVoice.male.url(for: "turn_left"))
        let female = try XCTUnwrap(PromptVoice.female.url(for: "turn_left"))
        XCTAssertNotEqual(male, female)
        XCTAssertNotEqual(try Data(contentsOf: male), try Data(contentsOf: female))
        XCTAssertEqual(male.deletingLastPathComponent().lastPathComponent, "male")
        XCTAssertEqual(female.deletingLastPathComponent().lastPathComponent, "female")
    }

    func testDecodeEveryClipAndMeasureResidualAACPadding() throws {
        var maxLeading = 0.0
        var maxTrailing = 0.0
        var count = 0
        for voice in PromptVoice.allCases {
            let directory = try XCTUnwrap(voice.url(for: "turn_left")).deletingLastPathComponent()
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "m4a" }
            XCTAssertEqual(urls.count, 238)
            for url in urls {
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
                XCTAssertEqual(file.processingFormat.channelCount, 1)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                          frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                let first = try XCTUnwrap(samples.firstIndex { abs($0) > VoicePCM.silenceThreshold })
                let last = try XCTUnwrap(samples.lastIndex { abs($0) > VoicePCM.silenceThreshold })
                maxLeading = max(maxLeading, Double(first) / file.processingFormat.sampleRate)
                maxTrailing = max(maxTrailing, Double(samples.count - 1 - last) / file.processingFormat.sampleRate)
                let trimmed = VoicePCM.trimmed(samples)
                XCTAssertEqual(trimmed.count, last - first + 1)
                count += 1
            }
        }
        print("AVAudioFile decoded \(count) AAC clips: maximum residual leading \(maxLeading * 1000) ms, trailing \(maxTrailing * 1000) ms; trimmed before joins")
    }
}
