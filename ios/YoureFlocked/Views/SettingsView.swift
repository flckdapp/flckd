import SwiftUI
import SwiftData

// MARK: - Settings View

/// App settings: alerts, camera filters, voice, navigation, display,
/// permissions, stored camera data and about info.
struct SettingsView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(CameraStore.self) private var cameraStore
    @Environment(NotificationManager.self) private var notificationManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(NavigationSessionController.self) private var navigationController
    @Environment(\.modelContext) private var modelContext

    @State private var suspectedCount: Int = 0
    @State private var suspectedLastDownload: Date?
    @State private var cacheCount: Int = 0
    @State private var cacheSizeBytes: Int64 = 0
    @State private var cdnTileCount: Int = 0
    @State private var cdnCacheBytes: Int64 = 0
    @State private var cdnSnapshotDate: Date?
    @State private var isDownloading: Bool = false
    @State private var downloadMessage: String?
    @State private var showClearCacheConfirmation: Bool = false

    @AppStorage(LocationManager.alertRadiusKey) private var alertRadius: Double = 200
    @AppStorage(CameraStore.fetchRadiusKey) private var fetchRadius: Double = 5.0
    @AppStorage("showALPROnly") private var showALPROnly: Bool = false
    @AppStorage(CameraStore.showSpeedCamerasKey) private var showSpeedCameras: Bool = true
    @AppStorage("showGenericCameras") private var showGenericCameras: Bool = true
    @AppStorage("alertMode") private var alertModeRaw: String = AlertMode.nearCamera.rawValue
    #if DEBUG
    @AppStorage("showDebugOverlay") private var showDebugOverlay: Bool = false
    #endif
    #if DEBUG
    @AppStorage("showRoutingSpikeOverlay") private var showRoutingSpikeOverlay: Bool = false
    #endif
    @AppStorage("showSuspectedLocations") private var showSuspectedLocations: Bool = false
    @AppStorage("offlineRadius") private var offlineRadius: Double = 20.0
    @AppStorage(DistanceUnits.storageKey) private var useMetric: Bool = false
    @AppStorage("enableHaptics") private var enableHaptics: Bool = true
    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = true
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(NavigationSessionController.voiceGuidanceKey) private var voiceGuidance: Bool = true
    @AppStorage(NavigationVoice.storageKey) private var promptVoice = NavigationVoice.defaultVoice.rawValue
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewing: String?
    @AppStorage(VoiceSettings.masterKey) private var voiceEnabled = true
    @AppStorage(VoiceSettings.trafficLightsKey) private var trafficLights = true
    @AppStorage(VoiceSettings.reroutingKey) private var reroutingAnnouncements = true
    @AppStorage(VoiceSettings.camerasKey) private var cameraAlerts = true
    @AppStorage(VoiceSettings.outsideNavigationKey) private var camerasOutsideNavigation = false

    // Section order is the order on screen: what the app does (alerts, filters,
    // voice, navigation), then how it looks, then permissions and stored data.
    var body: some View {
        Form {
            alertsSection
            cameraFiltersSection
            voiceSection
            navigationSection
            displaySection
            permissionsSection
            dataSection
            aboutSection
            #if DEBUG
            developerSection
            #endif
        }
        .onChange(of: [voiceEnabled, voiceGuidance, trafficLights,
                       reroutingAnnouncements, cameraAlerts, camerasOutsideNavigation]) { _, _ in
            VoicePromptPlayer.shared.settingsDidChange()
        }
        .onChange(of: promptVoice) { _, _ in
            VoicePromptPlayer.shared.settingsDidChange()
            PhononSpeechService.shared.warmUp()
        }
        .onChange(of: voiceEnabled) { _, _ in PhononSpeechService.shared.warmUp() }
    }

    // MARK: - Units

    private var units: DistanceUnits { useMetric ? .metric : .imperial }

    // MARK: - Alerts

    @ViewBuilder
    private var alertsSection: some View {
        Section("Alerts") {
            Toggle("Enable Alerts", isOn: Bindable(notificationManager).alertsEnabled)

            Picker("Alert Mode", selection: $alertModeRaw) {
                ForEach(AlertMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            if alertModeRaw == AlertMode.inFieldOfView.rawValue {
                Text("Alerts only when inside a camera's viewing angle. Cameras without direction data use distance only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DistanceSettingRow(
                title: "Alert Radius",
                scale: DistanceSetting.alertRadius.scale(for: units),
                stored: $alertRadius
            )
            .onChange(of: alertRadius) { _, newValue in
                locationManager.alertRadius = newValue
            }

            Toggle("Haptic Feedback", isOn: $enableHaptics)

            if notificationManager.mutedCount > 0 {
                LabeledContent("Muted Cameras", value: "\(notificationManager.mutedCount)")
                Button("Unmute All", role: .destructive) {
                    notificationManager.unmuteAll()
                }
            }
        }
        .onAppear { notificationManager.refreshMutes() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { notificationManager.refreshMutes() }
        }
    }

    // MARK: - Camera Filters

    @ViewBuilder
    private var cameraFiltersSection: some View {
        Section {
            Toggle("ALPR Cameras Only", isOn: $showALPROnly)
            if !showALPROnly {
                Toggle("Show Speed Cameras", isOn: $showSpeedCameras)
                Toggle("Show Generic Cameras", isOn: $showGenericCameras)
            }
            Toggle("Show Suspected Locations", isOn: $showSuspectedLocations)
        } header: {
            Text("Camera Filters")
        } footer: {
            Text("Filters change the map and alerts, but routing still avoids all camera types. Suspected locations appear on the map only.")
        }
    }

    // MARK: - Voice

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            Toggle("Voice", isOn: $voiceEnabled)
            NavigationLink {
                voiceSettingsView
            } label: {
                LabeledContent("Voice & Spoken Prompts", value: voiceEnabled ? selectedVoiceName : "Off")
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Spoken directions and camera alerts, played on this device.")
        }
    }

    private var selectedVoiceName: String {
        (NavigationVoice(rawValue: promptVoice) ?? .defaultVoice).name
    }

    private var tripRunning: Bool { navigationController.isActive || navigationController.isStarting }

    private var voiceSettingsView: some View {
        Form {
            voicePickerSection(live: true)
            voicePickerSection(live: false)
            spokenPromptsSection
            cameraVoiceSection
        }
        .onDisappear {
            previewTask?.cancel(); previewTask = nil; previewing = nil
            VoicePromptPlayer.shared.cancel(.sample)
        }
        .navigationTitle("Voice & Spoken Prompts")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func voicePickerSection(live: Bool) -> some View {
        Section {
            ForEach(NavigationVoice.allCases.filter { $0.live == live }, id: \.rawValue) { voice in
                HStack {
                    let selected = promptVoice == voice.rawValue
                    Button {
                        promptVoice = voice.rawValue
                    } label: {
                        HStack {
                            Text(voice.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(voice.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(tripRunning)
                    Button {
                        preview(voice)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Preview \(voice.name)")
                    .disabled(tripRunning || previewing != nil)
                }
            }
            if live, let previewError { Text(previewError).font(.caption).foregroundStyle(.red) }
        } header: {
            Text(live ? "Live" : "Recorded")
        } footer: {
            Text(live ? "Generated on this phone, including street names and exit numbers."
                      : "Pre-recorded fixed prompts, without street names.")
        }
    }

    private func preview(_ voice: NavigationVoice) {
        guard !tripRunning else { return }
        previewTask?.cancel()
        VoicePromptPlayer.shared.cancel(.sample)
        previewError = nil
        previewing = voice.rawValue
        previewTask = Task {
            defer { previewing = nil }
            if !voice.live { navigationController.playVoiceSample(voice.recording ?? .male); return }
            do {
                let pcm = try await PhononSpeechService.shared.preview(voice)
                try Task.checkCancellation()
                guard !tripRunning else { return }
                var utterance = VoiceUtterance.preview(voice: voice.recording ?? .male, now: ProcessInfo.processInfo.systemUptime)
                utterance.renderedPCM = pcm
                VoicePromptPlayer.shared.enqueue(utterance)
            } catch {
                if !Task.isCancelled { previewError = "This voice could not render. Try its preview again." }
            }
        }
    }

    private var spokenPromptsSection: some View {
        Section {
            Toggle("Turn-by-turn directions", isOn: $voiceGuidance)
            Toggle("Traffic lights", isOn: $trafficLights)
            Toggle("Rerouting announcements", isOn: $reroutingAnnouncements)
            Toggle("Camera alerts", isOn: $cameraAlerts)
            Toggle("Also when not navigating", isOn: $camerasOutsideNavigation)
                .disabled(!cameraAlerts)
        } header: {
            Text("Spoken Prompts")
        } footer: {
            Text("Camera alerts are independent of directions. The trip mute silences all speech for that trip.")
        }
        .disabled(!voiceEnabled)
    }

    private var cameraVoiceSection: some View {
        Section {
            ForEach(CameraVoiceType.allCases, id: \.rawValue) { type in
                CameraVoiceTypeToggle(type: type)
            }
        } header: {
            Text("Spoken Camera Types")
        } footer: {
            Text("Banners, haptics and notifications are unchanged.")
        }
        .disabled(!voiceEnabled || !cameraAlerts)
    }

    // MARK: - Navigation

    @ViewBuilder
    private var navigationSection: some View {
        Section {
            NavigationLink {
                OfflineRoutingView()
            } label: {
                let regionCount = RegionStore.installedRegions().count
                LabeledContent(
                    "Offline Routing",
                    value: regionCount == 0 ? "No regions" : "\(regionCount) region\(regionCount == 1 ? "" : "s")"
                )
            }
        } header: {
            Text("Navigation")
        } footer: {
            Text("Download road data so routes are computed on this device and your destination never leaves it.")
        }
    }

    // MARK: - Display

    @ViewBuilder
    private var displaySection: some View {
        Section {
            Picker("Theme", selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases, id: \.rawValue) { appearance in
                    Text(appearance.displayName).tag(appearance.rawValue)
                }
            }

            Picker("Distance Units", selection: $useMetric) {
                Text("Metric (km, m)").tag(true)
                Text("Standard (mi, ft)").tag(false)
            }

            Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
        } header: {
            Text("Display")
        } footer: {
            Text("Keep Screen Awake stops the screen locking while the map or a route is open. It uses more battery, so keep the phone on a charger for long drives.")
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent("Location Status") {
                Text(authStatusText)
                    .foregroundStyle(authStatusColor)
            }

            Button("Open Location Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }

            LabeledContent("Notification Status") {
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

    // MARK: - Data & Storage

    @ViewBuilder
    private var dataSection: some View {
        Section {
            NavigationLink("Camera Data") {
                cameraDataView
            }
        } header: {
            Text("Data & Storage")
        } footer: {
            Text("Where camera data comes from, how much is downloaded and what is stored on this device.")
        }
    }

    private var cameraDataView: some View {
        Form {
            cameraSourcesSection
            cameraCoverageSection
            cameraStorageSection
            suspectedLocationsSection
        }
        .task {
            await refreshCDNStatus()
            await refreshDataStats()
        }
        .navigationTitle("Camera Data")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var cameraSourcesSection: some View {
        Section {
            sourceRow(
                "ALPR Cameras",
                icon: "antenna.radiowaves.left.and.right",
                source: cameraStore.lastALPRSource?.rawValue ?? CameraStore.CameraDataSource.deflockCDN.rawValue,
                details: [cameraStore.lastALPRSource == .overpass ? nil : cdnSnapshotDate.map {
                    "Data from \($0.formatted(date: .abbreviated, time: .omitted))"
                }]
            )

            sourceRow(
                "Speed Cameras",
                icon: "gauge.with.needle",
                source: cameraStore.speedCameraSource,
                details: [
                    cameraStore.speedCameraCountLabel,
                    cameraStore.speedCameraDataDate.map { "Data from \(ReleaseDate.label($0))" },
                ]
            )
        } header: {
            Text("Sources")
        } footer: {
            Text("Bulk ALPR locations come from DeFlock's hourly snapshots and are cached on this device, so the map works during outages and offline. Speed and red-light cameras come from a national file downloaded with your first routing region; until then, and whenever DeFlock is down, the app asks OpenStreetMap's Overpass servers for one whole-degree grid cell at a time. Apple Maps tiles are not available for offline caching. Camera data \u{00A9} OpenStreetMap contributors (ODbL), via DeFlock and the tile server.")
        }
    }

    @ViewBuilder
    private var cameraCoverageSection: some View {
        Section("Coverage") {
            DistanceSettingRow(
                title: "Fetch Radius",
                scale: DistanceSetting.fetchRadius.scale(for: units),
                stored: $fetchRadius
            )
            .onChange(of: fetchRadius) { _, newValue in
                cameraStore.fetchRadiusKm = newValue
            }

            DistanceSettingRow(
                title: "Offline Download Radius",
                scale: DistanceSetting.offlineRadius.scale(for: units),
                stored: $offlineRadius
            )

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
        }
    }

    @ViewBuilder
    private var cameraStorageSection: some View {
        Section("Storage") {
            LabeledContent("Cached Cameras", value: "\(cacheCount)")

            LabeledContent(
                "Downloaded Area Data",
                value: ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
            )

            LabeledContent("Offline Tile Cache", value: cdnCacheSummary)

            if cameraStore.pendingCount > 0 {
                LabeledContent("Pending Uploads") {
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
        }
    }

    @ViewBuilder
    private var suspectedLocationsSection: some View {
        Section("Suspected Locations") {
            LabeledContent("Loaded Suspected Locations", value: "\(suspectedCount)")

            LabeledContent(
                "Last Download",
                value: suspectedLastDownload?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
            )
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
        cdnSnapshotDate = status.snapshotDate
    }

    /// Title and details on the left, source on the right; stacked at
    /// accessibility text sizes, where two columns would hyphenate both.
    private func sourceRow(_ title: String, icon: String, source: String, details: [String?]) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        return layout {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    ForEach(details.compactMap { $0 }, id: \.self) { detail in
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: icon)
            }
            if !stacked { Spacer() }
            Text(source)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - About

    /// "0.1.0 (4)", read from the bundle so it always matches project.yml.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)

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

            NavigationLink {
                licencesView
            } label: {
                Label("Open-source Licences", systemImage: "doc.text")
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

    // MARK: - Licences

    @ViewBuilder
    private var licencesView: some View {
        Form {
            Section {
                licenceRow(
                    "valhalla-mobile",
                    licence: "MIT",
                    detail: "The routing engine. Plans every route on this device.",
                    url: URL(string: "https://github.com/rallista/valhalla-mobile")!
                )

                licenceRow(
                    "Ferrostar",
                    licence: "BSD-3-Clause",
                    detail: "Turn-by-turn guidance. Bundles Mozilla\u{2019}s UniFFI runtime, which is MPL-2.0.",
                    url: URL(string: "https://github.com/stadiamaps/ferrostar")!
                )

                licenceTextRow("xn-ptts", licence: "MIT OR Apache-2.0",
                               detail: "On-device speech runtime. No server is used.", resource: "xn-ptts")
            } footer: {
                Text("None of these libraries talks to a server in this app.")
            }
            Section("Voice Prompts") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Generated with ElevenLabs")
                    Text("Eric and Jessica. Generic prompts generated during development and shipped as audio files in the app. No ElevenLabs service runs in the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                licenceTextRow("Phonon 31m", licence: "Apache-2.0",
                               detail: "Bundled speech model and Easton and Harper voices.", resource: "phonon-31m")
            }
        }
        .navigationTitle("Open-source Licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenceTextRow(_ name: String, licence: String, detail: String, resource: String) -> some View {
        NavigationLink {
            LicenceTextView(title: name, resource: resource)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                    Spacer()
                    Text(licence)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func licenceRow(
        _ name: String,
        licence: String,
        detail: String,
        url: URL
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(name)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                }
                Spacer()
                Text(licence)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Developer

    #if DEBUG
    @ViewBuilder
    private var developerSection: some View {
        Section {
            Toggle("Routing Latency HUD", isOn: $showRoutingSpikeOverlay)
            NavigationLink("Phonon Bench") { PhononEvaluationView() }
            Toggle("Debug Overlay", isOn: $showDebugOverlay)
        } header: {
            Text("Developer")
        } footer: {
            Text("Shown in Debug builds only.")
        }
    }
    #endif

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
            let radius = DistanceSetting.offlineRadius.scale(for: units).step(nearest: offlineRadius).label
            downloadMessage = "Downloaded \(count) cameras within \(radius)"
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

/// A distance slider that moves between the steps of its scale. The stored
/// value stays metric and is only written when the slider reaches another step.
private struct DistanceSettingRow: View {
    let title: String
    let scale: DistanceSettingScale
    @Binding var stored: Double

    var body: some View {
        let shown = scale.step(nearest: stored)
        VStack(alignment: .leading) {
            LabeledContent(title, value: shown.label)
            Slider(value: position, in: 0...Double(scale.steps.count - 1), step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(shown.spokenLabel)
        }
    }

    private var position: Binding<Double> {
        Binding(
            get: { Double(scale.index(nearest: stored)) },
            set: { newValue in
                if let value = scale.stored(movingTo: Int(newValue.rounded()), from: stored) { stored = value }
            }
        )
    }
}

private struct CameraVoiceTypeToggle: View {
    let type: CameraVoiceType
    @AppStorage private var enabled: Bool

    init(type: CameraVoiceType) {
        self.type = type
        _enabled = AppStorage(wrappedValue: true, type.storageKey)
    }

    var body: some View {
        Toggle(type.title, isOn: $enabled)
            .onChange(of: enabled) { _, _ in VoicePromptPlayer.shared.settingsDidChange() }
    }
}

#Preview {
    let locationManager = LocationManager()
    let cameraStore = CameraStore()
    let liveActivityManager = LiveActivityManager()
    let proximityEngine = ProximityAlertEngine()

    NavigationStack {
        SettingsView()
            .environment(locationManager)
            .environment(cameraStore)
            .environment(NotificationManager())
            .environment(OfflineDataUpdater())
            .environment(NavigationSessionController(
                locationManager: locationManager,
                cameraStore: cameraStore,
                proximityEngine: proximityEngine,
                liveActivityManager: liveActivityManager,
                routingService: ValhallaRoutingService()
            ))
    }
}
