import Foundation
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// Receives guidance updates for the lock screen.
///
/// Ferrostar's own `TripActivityAttributes` is internal, so the app cannot
/// extend it. The app owns the attributes instead, which is also what lets one
/// Live Activity carry both the next maneuver and the camera warning rather
/// than two competing ones.
///
/// `WidgetProviding` is synchronous and non-isolated while `LiveActivityManager`
/// is main-actor isolated, so both methods below hop. Ferrostar makes every call
/// to this protocol from inside a `DispatchQueue.main.async` block — the update
/// in `FerrostarCore.update(_:location:)` and the `terminate()` in
/// `stopNavigation()` alike — so the hops are enqueued in the order Ferrostar
/// made them and a stale turn cannot land after the trip has ended.
final class FlckdNavigationWidgetProvider: WidgetProviding {

    private let liveActivityManager: LiveActivityManager

    init(liveActivityManager: LiveActivityManager) {
        self.liveActivityManager = liveActivityManager
    }

    func update(
        visualInstruction: VisualInstruction,
        spokenInstruction _: SpokenInstruction?,
        tripProgress: TripProgress
    ) {
        let banner = visualInstruction.primaryContent
        let maneuver = ManeuverType(
            osrmType: banner.maneuverType,
            modifier: banner.maneuverModifier,
            roundaboutExitDegrees: banner.roundaboutExitDegrees
        )
        // Ferrostar's own text names the street, so it beats the maneuver's
        // generic label whenever it is there.
        let instruction = banner.text.isEmpty ? maneuver.displayLabel : banner.text
        let distanceToNextTurn = tripProgress.distanceToNextManeuver
        let durationRemaining = tripProgress.durationRemaining
        let manager = liveActivityManager

        // `isRerouting` stays false: this protocol is handed an instruction and
        // a progress, and nothing else. `NavigationSessionController` is what
        // knows a reroute is in flight, and feeding that in means a call from
        // there, which is outside this change.
        Task { @MainActor in
            await manager.updateNavigation(
                maneuverCode: maneuver.rawValue,
                instruction: instruction,
                distanceToNextTurn: distanceToNextTurn,
                etaSecondsRemaining: durationRemaining,
                isRerouting: false
            )
        }
    }

    func terminate() {
        let manager = liveActivityManager

        Task { @MainActor in
            await manager.clearNavigation()
        }
    }
}
