import SwiftUI

struct ContentView: View {
    @Environment(LocationManager.self) private var locationManager
    @State private var selectedTab: Tab = .map
    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = true

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
        .task {
            locationManager.requestAuthorizationIfNeeded()
        }
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
}
