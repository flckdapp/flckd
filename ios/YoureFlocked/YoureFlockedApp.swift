import SwiftUI
import SwiftData
import ActivityKit
import UIKit

// MARK: - App Delegate

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if launchOptions?[.location] != nil {
            // Relaunched by significantLocationChanges after termination.
            // LocationManager will re-register via @State init and
            // locationManagerDidChangeAuthorization → startTracking().
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        let semaphore = DispatchSemaphore(value: 0)

        // `Activity` is not `Sendable`, so the activities are fetched and ended
        // entirely inside the detached task. Nothing crosses an actor boundary,
        // and the work runs off the main thread, so the wait cannot deadlock.
        Task.detached {
            await LiveActivityManager.endAllActivities()
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 3)
    }
}

// MARK: - App Entry Point

@main
struct YoureFlockedApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var locationManager = LocationManager()
    @State private var cameraStore = CameraStore()
    @State private var notificationManager = NotificationManager()
    @State private var liveActivityManager = LiveActivityManager()
    @State private var proximityEngine = ProximityAlertEngine()
    @State private var showSplash = true
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(locationManager)
                    .environment(cameraStore)
                    .environment(notificationManager)
                    .environment(liveActivityManager)
                    .environment(proximityEngine)

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(AppAppearance.stored(appearanceRaw).colorScheme)
            .task { @MainActor in
                await LiveActivityManager.endOrphanedActivitiesOnLaunch()
                if locationManager.isTracking {
                    liveActivityManager.startActivity(alertRadius: locationManager.alertRadius)
                }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.4)) {
                    showSplash = false
                }
            }
            .onChange(of: locationManager.isTracking) { _, isTracking in
                if isTracking {
                    liveActivityManager.startActivity(alertRadius: locationManager.alertRadius)
                } else {
                    Task { await liveActivityManager.endActivity() }
                }
            }
        }
        .modelContainer(for: [CachedCamera.self])
    }
}
