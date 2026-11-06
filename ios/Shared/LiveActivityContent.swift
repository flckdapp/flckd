import Foundation

/// The camera half of the Live Activity's payload.
///
/// Its defaults are the state a freshly requested activity starts in: nothing
/// found yet, and scanning.
struct CameraActivityFields: Equatable, Sendable {
    var nearbyCameraCount: Int = 0
    var nearestCameraDistance: Double = -1
    var nearestCameraBearing: Double = 0
    var nearestCameraType: String = ""
    var isTracking: Bool = true
}

/// The navigation half. Absent, rather than zeroed, when no trip is running.
struct NavigationActivityFields: Equatable, Sendable {
    var maneuverCode: Int?
    var instruction: String?
    var distanceToNextTurnMeters: Double?
    var eta: Date?
    var isRerouting: Bool = false
}

/// Builds the Live Activity payload from both halves at once.
///
/// Camera proximity and guidance arrive from different places at different
/// rates, and `ContentState` is replaced wholesale on every update, so whoever
/// pushes last would otherwise erase the other's fields: a camera update a
/// second after a turn instruction would blank the turn, and the next turn
/// would blank the camera warning. Composing from both stores means neither
/// can happen.
enum LiveActivityContent {

    static func compose(
        camera: CameraActivityFields,
        navigation: NavigationActivityFields?
    ) -> SurveillanceActivityAttributes.ContentState {
        SurveillanceActivityAttributes.ContentState(
            nearbyCameraCount: camera.nearbyCameraCount,
            nearestCameraDistance: camera.nearestCameraDistance,
            nearestCameraBearing: camera.nearestCameraBearing,
            nearestCameraType: camera.nearestCameraType,
            isTracking: camera.isTracking,
            nextManeuverCode: navigation?.maneuverCode,
            nextManeuverInstruction: navigation?.instruction,
            distanceToNextTurnMeters: navigation?.distanceToNextTurnMeters,
            eta: navigation?.eta,
            isRerouting: navigation.map(\.isRerouting)
        )
    }
}

/// Decides which guidance updates are worth one of ActivityKit's pushes.
///
/// Ferrostar hands over a new instruction on every location fix, which is about
/// once a second. ActivityKit budgets updates per app and starts dropping them,
/// so spending one on a distance that moved eight metres costs the update that
/// mattered. An update is worth making when the lock screen would actually draw
/// something different: a new instruction, a different arrow, a distance in a
/// new bucket, a new arrival minute, or the reroute spinner appearing or going
/// away.
struct NavigationUpdateThrottle {

    /// The fields behind what is currently on screen, not the last ones seen.
    private var lastPushed: NavigationActivityFields?

    /// The distance as drawn, in whole metres.
    ///
    /// Buckets are 50 m, tightening to 25 m inside 200 m where the number is
    /// changing fastest and the driver is reading it hardest. Bucketing to the
    /// rounded-down distance rather than to an index keeps two bucket sizes from
    /// colliding: 190 m and 350 m would share index 7 and the update would be
    /// thrown away.
    static func distanceBucket(forMeters meters: Double?) -> Int? {
        guard let meters, meters.isFinite else { return nil }

        let clamped = max(0, meters)
        let size: Double = clamped < 200 ? 25 : 50
        return Int((clamped / size).rounded(.down) * size)
    }

    /// The arrival time as drawn: to the minute.
    static func etaMinute(_ eta: Date?) -> Int? {
        guard let eta, eta.timeIntervalSinceReferenceDate.isFinite else { return nil }

        return Int((eta.timeIntervalSinceReferenceDate / 60).rounded(.down))
    }

    /// True when `fields` would change the lock screen. Records them as pushed
    /// when it answers true, so the caller must push if it does.
    mutating func shouldPush(_ fields: NavigationActivityFields) -> Bool {
        guard let last = lastPushed else {
            lastPushed = fields
            return true
        }

        let changed = last.instruction != fields.instruction
            || last.maneuverCode != fields.maneuverCode
            || last.isRerouting != fields.isRerouting
            || Self.distanceBucket(forMeters: last.distanceToNextTurnMeters)
                != Self.distanceBucket(forMeters: fields.distanceToNextTurnMeters)
            || Self.etaMinute(last.eta) != Self.etaMinute(fields.eta)

        if changed { lastPushed = fields }
        return changed
    }

    /// Records fields that reached the screen some other way, such as the
    /// initial content of a newly requested activity.
    mutating func recordPush(of fields: NavigationActivityFields) {
        lastPushed = fields
    }

    /// Forgets what is on screen, so the next update is pushed whatever it says.
    mutating func reset() {
        lastPushed = nil
    }
}
