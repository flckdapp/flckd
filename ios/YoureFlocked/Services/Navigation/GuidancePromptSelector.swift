import Foundation
@preconcurrency import FerrostarCoreFFI

enum GuidancePromptSelector {
    static let distances: [(key: String, meters: Double)] = [
        ("500ft", 152.4), ("1000ft", 304.8), ("quarter_mi", 402.336),
        ("half_mi", 804.672), ("1mi", 1609.344), ("2mi", 3218.688),
    ]
    static let actions = [
        "turn_left", "turn_right", "slight_left", "slight_right", "sharp_left", "sharp_right", "uturn",
        "keep_left", "keep_right", "keep_straight", "exit_left", "exit_right", "ramp_left", "ramp_right",
        "merge_left", "merge_right", "end_left", "end_right", "roundabout_1", "roundabout_2",
        "roundabout_3", "roundabout_4", "continue",
    ]
    static let signalActions: Set<String> = ["turn_left", "turn_right", "slight_left", "slight_right", "uturn", "continue"]
    static let lanes = ["lane_left", "lane_left2", "lane_right", "lane_right2", "lane_middle"]

    static var allKeys: Set<String> {
        var keys = Set(actions + lanes + ["depart", "arrive", "arrive_left", "arrive_right", "continue_long", "rerouting", "new_route"])
        for distance in distances {
            for action in actions { keys.insert("\(distance.key).\(action)") }
        }
        for signal in ["at_light", "at_next_light", "at_second_light"] {
            for action in signalActions { keys.insert("\(signal).\(action)") }
        }
        return keys
    }

    static func select(
        content: VisualInstructionContent?, distance: Double, roundaboutExit: UInt8? = nil,
        laneInfo: [LaneInfo]? = nil, signal: String? = nil, longContinue: Bool = false,
        lanesEnabled: Bool = true, trafficLightsEnabled: Bool = true
    ) -> [String] {
        guard let content, let action = action(content, roundaboutExit: roundaboutExit) else { return [] }
        if longContinue { return ["continue_long"] }
        if action == "depart" { return [action] }
        if action.hasPrefix("arrive"), distance < 150 { return [action] }
        // There are no distance-prefixed arrival recordings. Do not announce
        // arrival early; preserve the distance in the on-device fallback.
        if action.hasPrefix("arrive") { return [] }
        let approach = distance >= 150
        let key: String
        if trafficLightsEnabled, let signal, signalActions.contains(action) {
            key = "\(signal).\(action)"
        } else if approach {
            key = "\(nearestDistance(distance)).\(action)"
        } else {
            key = action
        }
        if lanesEnabled, approach, let lane = lane(laneInfo ?? content.laneInfo ?? []) { return [key, lane] }
        return [key]
    }

    static func isContinueReminder(text: String, distance: Double) -> Bool {
        distance >= 500 && text.lowercased().hasPrefix("continue")
    }

    static func nearestDistance(_ meters: Double) -> String {
        distances.min { abs($0.meters - meters) < abs($1.meters - meters) }?.key ?? "500ft"
    }

    static func action(_ content: VisualInstructionContent, roundaboutExit: UInt8?) -> String? {
        let modifier = content.maneuverModifier
        let left = modifier == .left || modifier == .slightLeft || modifier == .sharpLeft
        let right = modifier == .right || modifier == .slightRight || modifier == .sharpRight
        func sided(_ prefix: String) -> String? { left ? "\(prefix)_left" : right ? "\(prefix)_right" : nil }
        func turn() -> String? {
            switch modifier {
            case .left: return "turn_left"
            case .right: return "turn_right"
            case .slightLeft: return "slight_left"
            case .slightRight: return "slight_right"
            case .sharpLeft: return "sharp_left"
            case .sharpRight: return "sharp_right"
            case .uTurn: return "uturn"
            case .straight: return "continue"
            case nil: return nil
            }
        }
        switch content.maneuverType {
        case .depart: return "depart"
        case .arrive: return sided("arrive") ?? "arrive"
        case .turn, .newName, .continue: return turn() ?? "continue"
        case .fork: return sided("keep") ?? "keep_straight"
        case .offRamp: return sided("exit")
        case .onRamp: return sided("ramp")
        case .merge: return sided("merge")
        case .endOfRoad: return sided("end") ?? turn()
        case .roundabout, .rotary, .roundaboutTurn:
            if let exit = roundaboutExit, (1...4).contains(exit) { return "roundabout_\(exit)" }
            // Angles do not tell us how many exits exist. Speak the original
            // on-device instruction rather than inventing an exit number.
            if content.maneuverType == .roundaboutTurn, content.roundaboutExitDegrees == nil { return turn() }
            return nil
        case .exitRoundabout, .exitRotary, .notification, nil: return nil
        }
    }

    static func lane(_ lanes: [LaneInfo]) -> String? {
        let active = lanes.indices.filter { lanes[$0].active }
        guard (1...2).contains(active.count), active.count < lanes.count,
              let first = active.first, let last = active.last,
              last - first + 1 == active.count else { return nil }
        if first == 0 { return active.count == 1 ? "lane_left" : "lane_left2" }
        if last == lanes.count - 1 { return active.count == 1 ? "lane_right" : "lane_right2" }
        if active.count == 1, lanes.count % 2 == 1, first == lanes.count / 2 { return "lane_middle" }
        return nil
    }
}
