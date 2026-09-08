import SwiftUI
import UIKit

// MARK: - Keep Screen Awake

/// Stops the display auto-locking while `isEnabled` holds.
///
/// The map is meant to be watched while driving, and a driver isn't touching
/// the phone, so the idle timer would black the screen out mid-journey. Apple
/// names mapping apps as a sanctioned reason to disable it.
///
/// `isIdleTimerDisabled` is one global flag, and SwiftUI's `onAppear` and
/// `onDisappear` fire out of order across `TabView` tabs, so this is applied
/// from a view that stays in the hierarchy and recomputed from `isEnabled`
/// and the scene phase rather than driven by appearance events. The flag is
/// cleared whenever the app leaves the foreground so it never outlives the
/// screen that asked for it.
@MainActor
private struct KeepScreenAwakeModifier: ViewModifier {
    let isEnabled: Bool

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { apply(scenePhase) }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .onChange(of: isEnabled) { _, _ in apply(scenePhase) }
            .onChange(of: scenePhase) { _, phase in apply(phase) }
    }

    private func apply(_ phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = isEnabled && phase == .active
    }
}

extension View {
    func keepScreenAwake(_ isEnabled: Bool) -> some View {
        modifier(KeepScreenAwakeModifier(isEnabled: isEnabled))
    }
}
