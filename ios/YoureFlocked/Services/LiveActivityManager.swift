import ActivityKit
import Foundation
import Observation

/// Duration after which a Live Activity's content is considered stale.
private let liveActivityStaleDuration: TimeInterval = 300

/// Used only when guidance needs an activity before the camera path ever asked
/// for one and the setting has never been written. Matches `LocationManager`'s
/// own default, which the slider in Settings starts at.
private let fallbackAlertRadius: Double = 200

/// Manages the lifecycle of the surveillance-tracking Live Activity.
///
/// `ActivityKit.Activity` is not `Sendable`, and its `request`, `update`, and
/// `end` members are `nonisolated`, so an `Activity` cannot cross an actor
/// boundary. This main-actor class therefore stores only the activity id (a
/// `String`), and every ActivityKit object is confined to the `nonisolated`
/// helpers in the extension below.
///
/// One activity carries both the camera warning and the next turn. The two
/// halves are held separately and every payload is composed from both, because
/// `ContentState` is replaced wholesale: pushing only what just changed would
/// blank the other half.
@MainActor
@Observable
final class LiveActivityManager {

    /// True while a Live Activity started by this manager is on screen.
    private(set) var isActivityRunning: Bool = false

    /// Identifier of the activity this manager owns, if any.
    private var currentActivityID: String?

    /// The camera numbers from the last proximity update. Kept even with no
    /// activity on screen, so one requested later opens with what the app
    /// already knows rather than with zeros.
    private var lastCameraFields = CameraActivityFields()

    /// The guidance numbers from the last Ferrostar instruction, `nil` when no
    /// trip is running. Always the newest known values, including the ones the
    /// throttle decided not to spend a push on: a camera update that follows
    /// carries them for free.
    private var navigationFields: NavigationActivityFields?

    /// Owned here rather than passed with each instruction: Ferrostar stops
    /// handing over instructions while the driver is completely off the route,
    /// which is exactly when a reroute runs, so the flag has to be settable
    /// without one.
    private var navigationRerouting = false

    private var navigationThrottle = NavigationUpdateThrottle()

    /// The radius the camera path last asked for, so an activity requested by
    /// guidance describes the same detection zone.
    private var lastAlertRadius: Double?

    /// True while the activity on screen exists only because guidance asked for
    /// one. It ends with the trip; an activity the camera path owns does not.
    private var navigationOwnsActivity = false

    /// Whether the user has Live Activities enabled for this app.
    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    /// Starts a Live Activity, unless one is already running or the feature is off.
    func startActivity(alertRadius: Double) {
        lastAlertRadius = alertRadius

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard currentActivityID == nil else {
            // Guidance got there first. Tracking now wants this activity too,
            // so the end of the trip must not take it away.
            navigationOwnsActivity = false
            return
        }
        guard let id = Self.requestActivity(
            alertRadius: alertRadius,
            initialState: composedState()
        ) else { return }

        currentActivityID = id
        isActivityRunning = true
        navigationOwnsActivity = false
    }

    /// Pushes new proximity data to the running Live Activity.
    func update(
        nearbyCameraCount: Int,
        nearestDistance: Double,
        nearestBearing: Double,
        nearestCameraType: String,
        isTracking: Bool
    ) async {
        lastCameraFields = CameraActivityFields(
            nearbyCameraCount: nearbyCameraCount,
            nearestCameraDistance: nearestDistance,
            nearestCameraBearing: nearestBearing,
            nearestCameraType: nearestCameraType,
            isTracking: isTracking
        )

        guard let id = currentActivityID else { return }

        await Self.updateActivity(id: id, state: composedState())
    }

    /// Pushes the next turn to the running Live Activity, starting one if
    /// guidance is the first thing to want it.
    ///
    /// Distances are in metres and `etaSecondsRemaining` is the trip duration
    /// left, which is turned into an arrival time here: the payload stores a
    /// date so the lock screen stays truthful between updates.
    func updateNavigation(
        maneuverCode: Int?,
        instruction: String?,
        distanceToNextTurn: Double?,
        etaSecondsRemaining: Double?
    ) async {
        let fields = NavigationActivityFields(
            maneuverCode: maneuverCode,
            instruction: instruction,
            distanceToNextTurnMeters: distanceToNextTurn,
            eta: etaSecondsRemaining.map { Date.now.addingTimeInterval($0) },
            isRerouting: navigationRerouting
        )
        await pushNavigation(fields)
    }

    /// Shows or hides the reroute spinner on the running Live Activity.
    func setNavigationRerouting(_ rerouting: Bool) async {
        navigationRerouting = rerouting
        guard var fields = navigationFields else { return }
        fields.isRerouting = rerouting
        await pushNavigation(fields)
    }

    private func pushNavigation(_ fields: NavigationActivityFields) async {
        navigationFields = fields

        guard let id = currentActivityID else {
            // A trip can run with camera tracking switched off, in which case
            // nobody has requested an activity yet. The turn is worth a lock
            // screen on its own, and the camera row comes along with it.
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            guard let id = Self.requestActivity(
                alertRadius: lastAlertRadius ?? Self.storedAlertRadius(),
                initialState: composedState()
            ) else { return }

            currentActivityID = id
            isActivityRunning = true
            navigationOwnsActivity = true
            navigationThrottle.recordPush(of: fields)
            return
        }

        guard navigationThrottle.shouldPush(fields) else { return }

        await Self.updateActivity(id: id, state: composedState())
    }

    /// Takes the turn off the Live Activity when guidance stops.
    func clearNavigation() async {
        navigationFields = nil
        navigationRerouting = false
        navigationThrottle.reset()

        guard let id = currentActivityID else { return }

        guard !navigationOwnsActivity else {
            // Nothing else asked for this activity, so it goes with the trip
            // instead of sitting on the lock screen until it goes stale.
            await endActivity()
            return
        }

        await Self.updateActivity(id: id, state: composedState())
    }

    /// Ends the Live Activity owned by this manager.
    func endActivity() async {
        guard let id = currentActivityID else { return }

        // Clear local state first so a concurrent call cannot end the same
        // activity twice, then perform the ActivityKit work off the main actor.
        currentActivityID = nil
        isActivityRunning = false
        navigationOwnsActivity = false
        navigationFields = nil
        navigationRerouting = false
        navigationThrottle.reset()
        lastCameraFields = CameraActivityFields()

        await Self.endActivity(id: id)
    }

    // MARK: - Content

    private func composedState() -> SurveillanceActivityAttributes.ContentState {
        LiveActivityContent.compose(camera: lastCameraFields, navigation: navigationFields)
    }

    /// The alert radius as the user last left it, read from the key Settings'
    /// slider writes. Only consulted when guidance needs an activity in a
    /// session where tracking never started.
    private static func storedAlertRadius(
        _ defaults: UserDefaults = .standard
    ) -> Double {
        let stored = defaults.double(forKey: LocationManager.alertRadiusKey)
        return stored > 0 ? stored : fallbackAlertRadius
    }
}

// MARK: - ActivityKit bridge

/// All members below are `nonisolated`, so every `Activity` value is created and
/// consumed in the same non-isolated region and never crosses an actor boundary.
extension LiveActivityManager {

    /// Requests a new Live Activity and returns its id, or `nil` on failure.
    nonisolated static func requestActivity(
        alertRadius: Double,
        initialState: SurveillanceActivityAttributes.ContentState
    ) -> String? {
        let attributes = SurveillanceActivityAttributes(alertRadius: alertRadius)

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
        state: SurveillanceActivityAttributes.ContentState
    ) async {
        guard let activity = activity(withID: id) else { return }

        let content = ActivityContent(
            state: state,
            staleDate: Date.now.addingTimeInterval(liveActivityStaleDuration)
        )
        await activity.update(content)
    }

    /// Ends the activity with the given id, if it still exists.
    nonisolated static func endActivity(id: String) async {
        guard let activity = activity(withID: id) else { return }

        let finalState = LiveActivityContent.compose(
            camera: CameraActivityFields(isTracking: false),
            navigation: nil
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
