import Foundation
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// Receives guidance updates for the lock screen.
///
/// Ferrostar's own `TripActivityAttributes` is internal, so the app cannot
/// extend it. The app owns the attributes instead, which is also what lets one
/// Live Activity carry both the next maneuver and the camera warning rather
/// than two competing ones.
final class FlckdNavigationWidgetProvider: WidgetProviding {

    private let liveActivityManager: LiveActivityManager

    init(liveActivityManager: LiveActivityManager) {
        self.liveActivityManager = liveActivityManager
    }

    func update(
        visualInstruction _: VisualInstruction,
        spokenInstruction _: SpokenInstruction?,
        tripProgress _: TripProgress
    ) {
        // Filled in by the Live Activity job.
    }

    func terminate() {
        // Filled in by the Live Activity job.
    }
}
