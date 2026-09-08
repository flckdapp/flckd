import SwiftUI

struct ContentView: View {
    @Environment(LocationManager.self) private var locationManager
    @State private var selectedTab: Tab = .map
    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = true

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
        .keepScreenAwake(keepScreenAwake && selectedTab == .map)
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
