import Foundation

/// Distance crossings, not routing-engine voice trigger points, own timing.
/// State is per accepted route; `step` is its index, never a coordinate.
struct GuidancePromptSchedule {
    enum Prompt: Equatable {
        case continueRoad(String)
        case approach(String, meters: Double)
        case final
    }

    static let metersPerMile = 1609.344
    static let countdown: [(key: String, meters: Double)] = [
        ("2mi", 2 * metersPerMile), ("1mi", metersPerMile),
        ("half_mi", metersPerMile / 2), ("quarter_mi", metersPerMile / 4),
    ]
    static let continueKeys: Set<String> = Set((1...40).map { continueKey(quarters: $0) })
    private var step: Int?
    private var consumed = Set<String>()
    private var finalSpoken = false

    mutating func reset() { self = Self() }

    static func continueKey(miles: Double) -> String? {
        guard miles.isFinite, miles >= 0.125 else { return nil }
        guard miles <= 10 else { return "continue_long" }
        return continueKey(quarters: max(1, Int((miles * 4).rounded())))
    }

    private static func continueKey(quarters: Int) -> String {
        let fraction = String(format: "%02d", (quarters % 4) * 25)
        return "continue_mi.\(quarters / 4)_\(fraction)"
    }

    static func finalDistance(speed: Double) -> Double {
        min(150, max(30, effectiveSpeed(speed) * 6))
    }

    private static func effectiveSpeed(_ speed: Double) -> Double {
        speed.isFinite && speed >= 0 ? max(1, speed) : 13.4
    }

    mutating func update(step: Int, length: Double, remaining: Double, speed: Double) -> Prompt? {
        guard length.isFinite, remaining.isFinite, length >= 0, remaining >= 0 else { return nil }
        let entering = self.step != step
        if entering {
            self.step = step
            consumed.removeAll()
            finalSpoken = false
        }
        guard !finalSpoken else { return nil }
        let velocity = Self.effectiveSpeed(speed)
        let final = Self.finalDistance(speed: speed)
        let thresholds = length < Self.metersPerMile / 4
            ? [(key: "500ft", meters: 152.4)].filter { $0.meters < length }
            : Self.countdown.filter { $0.meters < length }

        // Consume every crossed threshold, including ones too close to final.
        // A sparse fix can cross several; only the nearest one is spoken.
        let crossed = thresholds.filter { !consumed.contains($0.key) && remaining <= $0.meters }
        for threshold in crossed { consumed.insert(threshold.key) }
        if remaining <= final {
            finalSpoken = true
            return .final
        }
        if let nearest = crossed.last, (remaining - final) / velocity > 2 {
            return .approach(nearest.key, meters: nearest.meters)
        }
        // Leave twelve seconds before the first countdown, avoiding a continue
        // immediately followed by an approach on short steps or late starts.
        if entering, crossed.isEmpty, let next = thresholds.first,
           (remaining - next.meters) / velocity >= 12,
           (next.meters - final) / velocity > 2,
           let key = Self.continueKey(miles: remaining / Self.metersPerMile) {
            return .continueRoad(key)
        }
        return nil
    }
}
