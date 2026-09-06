import ActivityKit
import Foundation
import Observation

/// Duration after which a Live Activity's content is considered stale.
private let liveActivityStaleDuration: TimeInterval = 300

/// Manages the lifecycle of the surveillance-tracking Live Activity.
///
/// `ActivityKit.Activity` is not `Sendable`, and its `request`, `update`, and
/// `end` members are `nonisolated`, so an `Activity` cannot cross an actor
/// boundary. This main-actor class therefore stores only the activity id (a
/// `String`), and every ActivityKit object is confined to the `nonisolated`
/// helpers in the extension below.
@MainActor
@Observable
final class LiveActivityManager {

    /// True while a Live Activity started by this manager is on screen.
    private(set) var isActivityRunning: Bool = false

    /// Identifier of the activity this manager owns, if any.
    private var currentActivityID: String?

    /// Whether the user has Live Activities enabled for this app.
    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    /// Starts a Live Activity, unless one is already running or the feature is off.
    func startActivity(alertRadius: Double) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard currentActivityID == nil else { return }
        guard let id = Self.requestActivity(alertRadius: alertRadius) else { return }

        currentActivityID = id
        isActivityRunning = true
    }

    /// Pushes new proximity data to the running Live Activity.
    func update(
        nearbyCameraCount: Int,
        nearestDistance: Double,
        nearestBearing: Double,
        nearestCameraType: String,
        isTracking: Bool
    ) async {
        guard let id = currentActivityID else { return }

        await Self.updateActivity(
            id: id,
            nearbyCameraCount: nearbyCameraCount,
            nearestDistance: nearestDistance,
            nearestBearing: nearestBearing,
            nearestCameraType: nearestCameraType,
            isTracking: isTracking
        )
    }

    /// Ends the Live Activity owned by this manager.
    func endActivity() async {
        guard let id = currentActivityID else { return }

        // Clear local state first so a concurrent call cannot end the same
        // activity twice, then perform the ActivityKit work off the main actor.
        currentActivityID = nil
        isActivityRunning = false

        await Self.endActivity(id: id)
    }
}

// MARK: - ActivityKit bridge

/// All members below are `nonisolated`, so every `Activity` value is created and
/// consumed in the same non-isolated region and never crosses an actor boundary.
extension LiveActivityManager {

    /// Requests a new Live Activity and returns its id, or `nil` on failure.
    nonisolated static func requestActivity(alertRadius: Double) -> String? {
        let attributes = SurveillanceActivityAttributes(alertRadius: alertRadius)
        let initialState = SurveillanceActivityAttributes.ContentState(
            nearbyCameraCount: 0,
            nearestCameraDistance: -1,
            nearestCameraBearing: 0,
            nearestCameraType: "",
            isTracking: true
        )

        do {
            let content = ActivityContent(
                state: initialState,
                staleDate: Date.now.addingTimeInterval(liveActivityStaleDuration)
            )
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            return activity.id
        } catch {
            print("[LiveActivityManager] Failed to start Live Activity: \(error)")
            return nil
        }
    }

    /// Updates the activity with the given id, if it still exists.
    nonisolated static func updateActivity(
        id: String,
        nearbyCameraCount: Int,
        nearestDistance: Double,
        nearestBearing: Double,
        nearestCameraType: String,
        isTracking: Bool
    ) async {
        guard let activity = activity(withID: id) else { return }

        let state = SurveillanceActivityAttributes.ContentState(
            nearbyCameraCount: nearbyCameraCount,
            nearestCameraDistance: nearestDistance,
            nearestCameraBearing: nearestBearing,
            nearestCameraType: nearestCameraType,
            isTracking: isTracking
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date.now.addingTimeInterval(liveActivityStaleDuration)
        )
        await activity.update(content)
    }

    /// Ends the activity with the given id, if it still exists.
    nonisolated static func endActivity(id: String) async {
        guard let activity = activity(withID: id) else { return }

        let finalState = SurveillanceActivityAttributes.ContentState(
            nearbyCameraCount: 0,
            nearestCameraDistance: -1,
            nearestCameraBearing: 0,
            nearestCameraType: "",
            isTracking: false
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        await activity.end(content, dismissalPolicy: .immediate)
    }

    /// Ends every surveillance activity, including ones left over from a previous
    /// process. Call this on launch and on termination.
    nonisolated static func endAllActivities() async {
        for activity in Activity<SurveillanceActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Clears activities that outlived the process that created them.
    nonisolated static func endOrphanedActivitiesOnLaunch() async {
        await endAllActivities()
    }

    /// Looks up an owned activity by id inside the non-isolated region.
    nonisolated private static func activity(
        withID id: String
    ) -> Activity<SurveillanceActivityAttributes>? {
        Activity<SurveillanceActivityAttributes>.activities.first { $0.id == id }
    }
}
