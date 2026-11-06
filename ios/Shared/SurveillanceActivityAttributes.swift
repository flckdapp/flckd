import ActivityKit
import Foundation

struct SurveillanceActivityAttributes: ActivityAttributes {
    var alertRadius: Double

    /// What the lock screen and the Dynamic Island draw.
    ///
    /// The five camera fields came first and are never optional. Every
    /// navigation field is, and that is load-bearing rather than tidy:
    /// ActivityKit keeps this value encoded and hands a payload written by the
    /// previous build to the new one after an app update, so a user mid-drive
    /// through an update has the original five keys on disk. Synthesised
    /// `Codable` decodes an optional with `decodeIfPresent`, so that payload
    /// still decodes and simply has no turn to show. A non-optional field would
    /// throw instead, which takes the camera warning off their lock screen —
    /// the thing the app exists to do.
    ///
    /// Nothing here locates anyone: the maneuver is a number, the instruction is
    /// the text already spoken aloud, and the distances and the arrival time are
    /// relative to a position that is never written down.
    struct ContentState: Codable, Hashable {
        var nearbyCameraCount: Int
        var nearestCameraDistance: Double
        var nearestCameraBearing: Double
        var nearestCameraType: String
        var isTracking: Bool

        /// ``ManeuverType``'s raw Valhalla code, resolved for drawing with
        /// `ManeuverType(code:).symbolName`. Carried as an `Int` rather than the
        /// enum so a code this build doesn't know survives the round-trip and
        /// degrades in one place.
        var nextManeuverCode: Int?

        var nextManeuverInstruction: String?
        var distanceToNextTurnMeters: Double?

        /// Arrival time, not seconds remaining. ActivityKit re-renders when it
        /// likes, so a duration is drawn stale and an arrival time derived from
        /// one at render time slides later on every render. An absolute date
        /// stays true between updates, which is also why it needs fewer of them.
        var eta: Date?

        var isRerouting: Bool?
    }
}

extension SurveillanceActivityAttributes.ContentState {

    /// True when there is a turn to draw.
    ///
    /// One predicate for every branch in the widget, so the lock screen and the
    /// Dynamic Island can't disagree about whether a trip is in progress.
    var hasNavigation: Bool {
        nextManeuverCode != nil || nextManeuverInstruction != nil
    }
}
