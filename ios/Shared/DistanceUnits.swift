import Foundation
import MapKit

enum DistanceUnits: String, Codable, CaseIterable, Sendable {
    case imperial, metric
    static let storageKey = "useMetric"

    static func selected(_ defaults: UserDefaults = .standard) -> Self {
        defaults.bool(forKey: storageKey) ? .metric : .imperial
    }

    var formatterUnits: MKDistanceFormatter.Units { self == .metric ? .metric : .imperial }
}
