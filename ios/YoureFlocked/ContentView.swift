import SwiftUI

struct ContentView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(CameraStore.self) private var cameraStore
    @Environment(NotificationManager.self) private var notificationManager
    @Environment(LiveActivityManager.self) private var liveActivityManager
    @Environment(ProximityAlertEngine.self) private var proximityEngine
    @State private var selectedTab: Tab = .map
    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = true
    @AppStorage("alertMode") private var alertModeRaw: String = AlertMode.nearCamera.rawValue
    @AppStorage("enableHaptics") private var enableHaptics: Bool = true

    #if DEBUG
    /// Held in `@State` rather than read through `RerouteProbe.shared` inline.
    /// Observation of a bare singleton touched in `body` is easy to get wrong,
    /// and if it silently fails the screen sleeps mid-drive and every reroute
    /// after that measures a cold engine rebuild instead of a reroute.
    @State private var probe = RerouteProbe.shared

    private var diagnosticsHoldingScreen: Bool { probe.isRunning }
    #else
    private var diagnosticsHoldingScreen: Bool { false }
    #endif

    enum Tab: String, CaseIterable {
        case map = "Map"
        case route = "Route"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .map: return "map.fill"
            case .route: return "point.topleft.down.to.point.bottomright.curvepath.fill"
            case .settings: return "gear"
            }
        }

        /// Screens a driver looks at without touching the phone, so the idle
        /// timer would black them out mid-journey.
        var watchedWhileDriving: Bool {
            switch self {
            case .map, .route: return true
            case .settings: return false
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        // A sleeping screen backgrounds the app, and LocalValhallaEngine tears
        // down on didEnterBackground, so every probe reroute after that would
        // pay a cold rebuild and the drive would measure cold starts instead
        // of reroutes. One flag, one owner: fold the probe into the same
        // condition rather than applying a second modifier that fights it.
        .keepScreenAwake((keepScreenAwake && selectedTab.watchedWhileDriving) || diagnosticsHoldingScreen)
        // Both of these sit above the TabView on purpose. Proximity warning is
        // what the app is for, so neither the detection nor the banner may
        // depend on which tab is showing, or on the map having been opened.
        .overlay(alignment: .top) { proximityBanner }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            guard let location = newLocation else { return }
            proximityEngine.handleLocationUpdate(
                location: location,
                heading: locationManager.heading,
                cameraStore: cameraStore,
                notificationManager: notificationManager,
                liveActivityManager: liveActivityManager,
                alertRadius: locationManager.alertRadius,
                alertMode: AlertMode(rawValue: alertModeRaw) ?? .nearCamera,
                enableHaptics: enableHaptics
            )
        }
        .task {
            locationManager.requestAuthorizationIfNeeded()
        }
    }

    @ViewBuilder
    private var proximityBanner: some View {
        VStack {
            if let alert = proximityEngine.activeAlert {
                ProximityBannerView(alert: alert, tripStats: proximityEngine.tripStats)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
                    .padding(.top, 8)
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.25), value: proximityEngine.activeAlert != nil)
    }

    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .map:
            NavigationStack {
                CameraMapView()
                    .navigationTitle("You're Flocked")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // Serif wordmark (New York), matching the splash
                        // screen and the tile-server landing page.
                        ToolbarItem(placement: .principal) {
                            Text("You're Flocked")
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                        }
                    }
            }
        case .route:
            NavigationStack {
                RouteView()
                    .navigationTitle("Route Planner")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .settings:
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(LocationManager())
        .environment(CameraStore())
        .environment(NotificationManager())
        .environment(LiveActivityManager())
        .environment(ProximityAlertEngine())
}
