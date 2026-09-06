import ActivityKit
import Foundation

struct SurveillanceActivityAttributes: ActivityAttributes {
    var alertRadius: Double

    struct ContentState: Codable, Hashable {
        var nearbyCameraCount: Int
        var nearestCameraDistance: Double
        var nearestCameraBearing: Double
        var nearestCameraType: String
        var isTracking: Bool
    }
}
