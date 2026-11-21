import Foundation

// MARK: - Distance Setting Scale

/// The values one distance slider in Settings can take.
///
/// Distance settings are stored in metric under their existing keys, because
/// everything that reads them expects metres or kilometres. Standard units get
/// their own scale of round imperial values, so the slider never shows a
/// converted number such as 656 ft. A stored value that is not on the current
/// scale shows as the nearest step and is only rewritten when the control
/// moves to a different step.
struct DistanceSettingScale: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        /// What is stored when this step is chosen, in the setting's own
        /// metric unit (metres or kilometres).
        let stored: Double
        /// Exactly what the slider shows, e.g. "650 ft" or "3 mi".
        let label: String
        /// The same value for VoiceOver, without symbols or abbreviations.
        let spokenLabel: String
    }

    let steps: [Step]

    /// The step closest to a stored value. A tie goes to the smaller step.
    func index(nearest stored: Double) -> Int {
        var best = 0
        for index in steps.indices
        where abs(steps[index].stored - stored) < abs(steps[best].stored - stored) {
            best = index
        }
        return best
    }

    func step(nearest stored: Double) -> Step { steps[index(nearest: stored)] }

    /// The value to store when the control moves to `index`, or nil when that
    /// is the step already shown, so a value nobody changed is never rewritten.
    func stored(movingTo index: Int, from current: Double) -> Double? {
        let target = min(max(index, 0), steps.count - 1)
        guard target != self.index(nearest: current) else { return nil }
        return steps[target].stored
    }
}

// MARK: - Distance Settings

/// One scale per setting and unit system. Metric scales are the ranges and
/// steps the sliders have always had.
enum DistanceSetting: CaseIterable, Sendable {
    /// Stored in metres.
    case alertRadius
    /// Stored in kilometres.
    case fetchRadius
    /// Stored in kilometres.
    case offlineRadius

    func scale(for units: DistanceUnits) -> DistanceSettingScale {
        switch (self, units) {
        case (.alertRadius, .metric):
            // 50-500 m in 25 m steps.
            return DistanceSettingScale(steps: (0...18).map { .meters(50 + 25 * $0) })
        case (.alertRadius, .imperial):
            // 150-1,650 ft in 50 ft steps: the same span, and the 200 m
            // default lands within a few feet of a step.
            return DistanceSettingScale(steps: (3...33).map { .feet(50 * $0) })
        case (.fetchRadius, .metric):
            // 1-20 km in 0.5 km steps.
            return DistanceSettingScale(steps: (2...40).map { .kilometers(Double($0) / 2) })
        case (.fetchRadius, .imperial):
            // Whole miles, 1-12: stays inside the metric 1-20 km range (the
            // 1 km floor leaves refetch headroom for the largest alert radius).
            return DistanceSettingScale(steps: (1...12).map { .miles($0) })
        case (.offlineRadius, .metric):
            // 5-50 km in 5 km steps.
            return DistanceSettingScale(steps: (1...10).map { .kilometers(Double(5 * $0)) })
        case (.offlineRadius, .imperial):
            // 5-30 mi in 5 mi steps, inside the metric 5-50 km range.
            return DistanceSettingScale(steps: (1...6).map { .miles(5 * $0) })
        }
    }
}

// MARK: - Steps

private extension DistanceSettingScale.Step {
    static let metersPerFoot = 0.3048
    static let kilometersPerMile = 1609.344 / 1000

    /// Metres, stored as metres.
    static func meters(_ meters: Int) -> Self {
        Self(stored: Double(meters), label: "\(meters)m", spokenLabel: "\(meters) meters")
    }

    /// Feet, stored as metres.
    static func feet(_ feet: Int) -> Self {
        let digits = feet >= 1000 ? "\(feet / 1000),\(String(format: "%03d", feet % 1000))" : "\(feet)"
        return Self(stored: Double(feet) * metersPerFoot, label: "\(digits) ft", spokenLabel: "\(feet) feet")
    }

    /// Kilometres, stored as kilometres.
    static func kilometers(_ kilometers: Double) -> Self {
        let digits = String(format: "%.1f", kilometers)
        return Self(stored: kilometers, label: "\(digits) km", spokenLabel: "\(digits) kilometers")
    }

    /// Whole miles, stored as kilometres.
    static func miles(_ miles: Int) -> Self {
        Self(stored: Double(miles) * kilometersPerMile, label: "\(miles) mi",
             spokenLabel: "\(miles) \(miles == 1 ? "mile" : "miles")")
    }
}
