import SwiftUI
import SwiftData

// MARK: - Settings View

/// App settings for alert configuration, data sources, and about info.
struct SettingsView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(CameraStore.self) private var cameraStore
    @Environment(NotificationManager.self) private var notificationManager
    @Environment(\.modelContext) private var modelContext

    @State private var suspectedCount: Int = 0
    @State private var suspectedLastDownload: Date?
    @State private var cacheCount: Int = 0
    @State private var cacheSizeBytes: Int64 = 0
    @State private var cdnTileCount: Int = 0
    @State private var cdnCacheBytes: Int64 = 0
    @State private var isDownloading: Bool = false
    @State private var downloadMessage: String?
    @State private var showClearCacheConfirmation: Bool = false

    @AppStorage("alertRadius") private var alertRadius: Double = 200
    @AppStorage("fetchRadius") private var fetchRadius: Double = 5.0
    @AppStorage("showALPROnly") private var showALPROnly: Bool = false
    @AppStorage("showSpeedCameras") private var showSpeedCameras: Bool = true
    @AppStorage("showGenericCameras") private var showGenericCameras: Bool = true
    @AppStorage("alertMode") private var alertModeRaw: String = AlertMode.nearCamera.rawValue
    @AppStorage("showDebugOverlay") private var showDebugOverlay: Bool = false
    @AppStorage("showSuspectedLocations") private var showSuspectedLocations: Bool = false
    @AppStorage("offlineRadius") private var offlineRadius: Double = 20.0
    @AppStorage("useMetric") private var useMetric: Bool = false
    @AppStorage("enableHaptics") private var enableHaptics: Bool = true
    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = true
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        Form {
            appearanceSection
            unitsSection
            mapSection
            alertSection
            routingSection
            filterSection
            suspectedLocationsSection
            cameraDataSection
            locationSection
            aboutSection
        }
        .task {
            await refreshDataStats()
        }
    }

    // MARK: - Units

    private func formatMeters(_ meters: Double) -> String {
        if useMetric {
            return "\(Int(meters))m"
        } else {
            let feet = meters * 3.28084
            return "\(Int(feet))ft"
        }
    }

    private func formatKm(_ km: Double) -> String {
        if useMetric {
            return String(format: "%.1f km", km)
        } else {
            let miles = km * 0.621371
            return String(format: "%.1f mi", miles)
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases, id: \.rawValue) { appearance in
                    Text(appearance.displayName).tag(appearance.rawValue)
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Automatic follows your device's Light or Dark setting.")
        }
    }

    // MARK: - Units

    @ViewBuilder
    private var unitsSection: some View {
        Section("Units") {
            Picker("Distance Units", selection: $useMetric) {
                Text("Metric (km, m)").tag(true)
                Text("Standard (mi, ft)").tag(false)
            }
        }
    }

    // MARK: - Map

    @ViewBuilder
    private var mapSection: some View {
        Section {
            Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
        } header: {
            Text("Map")
        } footer: {
            Text("Stops the screen locking while the map is open. Uses more battery, so keep the phone on a charger for long drives.")
        }
    }

    // MARK: - Alert Settings

    @ViewBuilder
    private var alertSection: some View {
        Section("Proximity Alerts") {
            Toggle("Enable Alerts", isOn: Bindable(notificationManager).alertsEnabled)

            Picker("Alert Mode", selection: $alertModeRaw) {
                ForEach(AlertMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Alert Radius")
                    Spacer()
                    Text(formatMeters(alertRadius))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $alertRadius, in: 50...500, step: 25)
            }
            .onChange(of: alertRadius) { _, newValue in
                locationManager.alertRadius = newValue
            }

            if alertModeRaw == AlertMode.inFieldOfView.rawValue {
                Text("Alerts only when inside a camera's viewing angle. Cameras without direction data use distance only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Haptic Feedback", isOn: $enableHaptics)

            HStack {
                Text("Notification Status")
                Spacer()
                Text(notificationManager.isAuthorized ? "Enabled" : "Disabled")
                    .foregroundStyle(notificationManager.isAuthorized ? .green : .red)
            }

            if !notificationManager.isAuthorized {
                Button("Enable Notifications") {
                    Task { await notificationManager.requestAuthorization() }
                }
            }
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var routingSection: some View {
        Section {
            NavigationLink {
                OfflineRoutingView()
            } label: {
                HStack {
                    Label("Offline Routing", systemImage: "map")
                    Spacer()
                    if RegionStore.installedRegions().isEmpty {
                        Text("No regions")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(RegionStore.installedRegions().count) region\(RegionStore.installedRegions().count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Download road data so routes are computed on this device and your destination never leaves it.")
        }
    }

    // MARK: - Filter Settings

    @ViewBuilder
    private var filterSection: some View {
        Section("Camera Filters") {
            Toggle("ALPR Cameras Only", isOn: $showALPROnly)
            if !showALPROnly {
                Toggle("Show Speed Cameras", isOn: $showSpeedCameras)
                Toggle("Show Generic Cameras", isOn: $showGenericCameras)
            }
        }
    }

    // MARK: - Camera Data

    @ViewBuilder
    private var cameraDataSection: some View {
        Section {
            HStack {
                Label("ALPR Cameras", systemImage: "antenna.radiowaves.left.and.right")
                Spacer()
                Text(cameraStore.lastALPRSource?.rawValue ?? "DeFlock CDN")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Speed Cameras", systemImage: "gauge.with.needle")
                Spacer()
                Text("OpenStreetMap (Overpass)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Last Updated")
                Spacer()
                if let date = cameraStore.lastFetchDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not yet fetched")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Fetch Radius")
                    Spacer()
                    Text(formatKm(fetchRadius))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $fetchRadius, in: 1...20, step: 0.5)
            }
            .onChange(of: fetchRadius) { _, newValue in
                cameraStore.fetchRadiusKm = newValue
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Offline Download Radius")
                    Spacer()
                    Text(formatKm(offlineRadius))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $offlineRadius, in: 5...50, step: 5)
            }

            Button {
                Task { await downloadOfflineData() }
            } label: {
                HStack {
                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isDownloading ? "Downloading..." : "Download Cameras for Offline")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(isDownloading || locationManager.currentLocation == nil)

            if let message = downloadMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Cached Cameras")
                Spacer()
                Text("\(cacheCount)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Downloaded Area Data")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Offline Tile Cache")
                Spacer()
                Text(cdnCacheSummary)
                    .foregroundStyle(.secondary)
            }

            if cameraStore.pendingCount > 0 {
                HStack {
                    Text("Pending Uploads")
                    Spacer()
                    Text("\(cameraStore.pendingCount)")
                        .foregroundStyle(.orange)
                }
            }

            Button("Clear Camera Data", role: .destructive) {
                showClearCacheConfirmation = true
            }
            .confirmationDialog(
                "Clear all camera data?",
                isPresented: $showClearCacheConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Camera Data", role: .destructive) {
                    cameraStore.clearCache(context: modelContext)
                    cameraStore.cameras = []
                    Task {
                        await cameraStore.clearCDNCache()
                        await refreshCDNStatus()
                        await refreshDataStats()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all camera data stored on this device — downloaded areas and offline tiles. Cameras will reload from the network next time they're needed.")
            }
        } header: {
            Text("Camera Data")
        } footer: {
            Text("Bulk ALPR locations come from DeFlock's hourly snapshots and are cached on this device, so the map works during outages and offline. Speed cameras and live updates use the OpenStreetMap Overpass API. Apple Maps tiles are not available for offline caching. Camera data \u{00A9} OpenStreetMap contributors (ODbL), via DeFlock.")
        }
        .task {
            await refreshCDNStatus()
        }
    }

    private var cdnCacheSummary: String {
        guard cdnTileCount > 0 else { return "Empty" }
        let size = ByteCountFormatter.string(fromByteCount: cdnCacheBytes, countStyle: .file)
        return "\(cdnTileCount) tile\(cdnTileCount == 1 ? "" : "s") \u{00B7} \(size)"
    }

    private func refreshCDNStatus() async {
        let status = await cameraStore.cdnStatus()
        cdnTileCount = status.cachedTileCount
        cdnCacheBytes = status.cachedBytes
    }

    // MARK: - Location

    @ViewBuilder
    private var locationSection: some View {
        Section("Location") {
            HStack {
                Text("Location Status")
                Spacer()
                Text(authStatusText)
                    .foregroundStyle(authStatusColor)
            }

            Button("Open Location Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }

            Toggle("Debug Overlay", isOn: $showDebugOverlay)
        }
    }

    // MARK: - Suspected Locations

    @ViewBuilder
    private var suspectedLocationsSection: some View {
        Section("Suspected Locations") {
            Toggle("Show Suspected Locations", isOn: $showSuspectedLocations)

            HStack {
                Text("Loaded Suspected Locations")
                Spacer()
                Text("\(suspectedCount)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Last Download")
                Spacer()
                if let suspectedLastDownload {
                    Text(suspectedLastDownload.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://deflock.me")!) {
                Label("DeFlock Project", systemImage: "globe")
            }

            Link(destination: URL(string: "https://wiki.openstreetmap.org/wiki/Tag:man_made%3Dsurveillance")!) {
                Label("OSM Surveillance Tags Wiki", systemImage: "book")
            }

            Link(destination: URL(string: "https://atlasofsurveillance.org")!) {
                Label("EFF Atlas of Surveillance", systemImage: "shield.lefthalf.filled")
            }

            Link(destination: URL(string: "https://github.com/FoggedLens/deflock-app")!) {
                Label("DeFlock Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } header: {
            Text("About")
        } footer: {
            VStack(spacing: 4) {
                Text("Camera data from OpenStreetMap contributors.")
                Text("This app does not collect or transmit personal data.")
            }
            .font(.caption)
        }
    }

    // MARK: - Helpers

    private var authStatusText: String {
        switch locationManager.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When In Use"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    private var authStatusColor: Color {
        switch locationManager.authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        default: return .red
        }
    }

    @MainActor
    private func downloadOfflineData() async {
        guard let coordinate = locationManager.currentLocation?.coordinate else { return }
        isDownloading = true
        downloadMessage = nil
        do {
            let count = try await cameraStore.downloadArea(
                around: coordinate,
                radiusKm: offlineRadius,
                context: modelContext
            )
            downloadMessage = "Downloaded \(count) cameras within \(formatKm(offlineRadius))"
            await refreshDataStats()
        } catch {
            downloadMessage = "Download failed: \(error.localizedDescription)"
        }
        isDownloading = false
    }

    private func refreshDataStats() async {
        let suspectedMetadata = await SuspectedLocationService.shared.cachedMetadata()
        suspectedCount = suspectedMetadata.count
        suspectedLastDownload = suspectedMetadata.lastDownload

        let stats = cameraStore.cacheStats(context: modelContext)
        cacheCount = stats.count
        cacheSizeBytes = stats.sizeBytes
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(LocationManager())
            .environment(CameraStore())
            .environment(NotificationManager())
    }
}
