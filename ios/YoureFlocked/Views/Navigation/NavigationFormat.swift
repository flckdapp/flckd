import Foundation
import MapKit
import SwiftUI

/// Distance, duration and arrival text for the driving screen.
///
/// `MKDistanceFormatter` rather than the hand-rolled formatting the rest of the
/// app uses: a turn banner has to round the way a driver reads it ("500 ft",
/// not "528 ft"), and the unit names come out localised. Both unit systems are
/// built from the app's own `useMetric` setting rather than the device locale,
/// so the banner agrees with the route card the user just looked at.
@MainActor
struct NavigationFormat {

    let useMetric: Bool

    /// One formatter per unit system for the whole app. The banner reformats on
    /// every location fix, and `MKDistanceFormatter` is not cheap to build.
    private static let metricFormatter = makeFormatter(units: .metric)
    private static let imperialFormatter = makeFormatter(units: .imperial)

    private static func makeFormatter(units: MKDistanceFormatter.Units) -> MKDistanceFormatter {
        let formatter = MKDistanceFormatter()
        formatter.units = units
        formatter.unitStyle = .abbreviated
        return formatter
    }

    private var distanceFormatter: MKDistanceFormatter {
        useMetric ? Self.metricFormatter : Self.imperialFormatter
    }

    func distance(_ meters: CLLocationDistance) -> String {
        distanceFormatter.string(fromDistance: max(0, meters))
    }

    /// Short enough to read at a glance: "25 min", "1h 5m". Deliberately the
    /// same shape as the route planner's own summary.
    func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }

    /// Clock time of arrival, `seconds` from `now`.
    func arrival(in seconds: TimeInterval, from now: Date = Date()) -> String {
        now.addingTimeInterval(max(0, seconds))
            .formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Palette

/// The route accent, named once.
///
/// The same teal is written as a literal in a dozen places across the older
/// views. The driving screen uses it on the polyline, the puck, the banner and
/// two buttons, and those four have to stay in step with each other.
enum NavigationPalette {
    static let accent = Color(red: 0.0, green: 0.7, blue: 0.65)
}
