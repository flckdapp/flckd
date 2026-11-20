import Foundation
@preconcurrency import FerrostarCoreFFI

enum SpeechAheadPlanner {
    struct Step {
        let banner: VisualInstructionContent?
        let lanes: [LaneInfo]?
        let distance: Double
        let exit: UInt8?
    }

    static func steps(_ steps: [RouteStep]) -> [Step] {
        steps.map { Step(banner: $0.visualInstructions.first?.primaryContent,
                         lanes: $0.visualInstructions.first?.subContent?.laneInfo,
                         distance: $0.distance, exit: $0.roundaboutExitNumber) }
    }

    static func windowIndices(count: Int) -> Range<Int> { 0..<min(3, max(0, count)) }

    static func utterances(steps: [Step], units: DistanceUnits, voice: NavigationVoice,
                           lanesEnabled: Bool, lightsEnabled: Bool) -> [VoiceUtterance] {
        var result: [VoiceUtterance] = []
        for offset in windowIndices(count: steps.count) {
            let step = steps[offset]
            guard let banner = step.banner else { continue }
            let exit = offset + 1 < steps.count ? steps[offset + 1].exit : nil
            var choices = [(distance: 0.0, approach: false)]
            choices += GuidancePromptSchedule.approachThresholds(length: step.distance, units: units).map { ($0.meters, true) }
            for choice in choices {
                let signals: [String?] = lightsEnabled ? [nil, choice.approach ? "at_next_light" : "at_light", "at_second_light"] : [nil]
                for signal in signals {
                    let keys = GuidancePromptSelector.select(content: banner, distance: choice.distance, roundaboutExit: exit,
                        laneInfo: step.lanes, signal: signal, lanesEnabled: lanesEnabled,
                        trafficLightsEnabled: lightsEnabled, isApproach: choice.approach, units: units)
                    guard !keys.isEmpty else { continue }
                    result.append(VoiceUtterance(clips: keys, voice: voice.recorded, createdAt: 0,
                        liveVoice: voice, roadName: banner.text, exitNumber: banner.exitNumbers.first))
                }
            }
            if let key = GuidancePromptSchedule.continueKey(meters: step.distance, units: units) {
                result.append(VoiceUtterance(clips: [key], voice: voice.recorded, createdAt: 0, liveVoice: voice))
            }
        }
        return result
    }
}
