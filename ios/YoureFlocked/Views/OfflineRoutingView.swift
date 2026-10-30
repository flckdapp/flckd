import SwiftUI

// MARK: - Offline Routing Settings

/// Settings screen for on-device routing: tile server, downloaded regions,
/// and the offline-only policy. Reached from SettingsView.
struct OfflineRoutingView: View {
    @AppStorage("tileServerURL") private var tileServerURL: String = TilePackService.defaultServerURL
    @Environment(CameraStore.self) private var cameraStore
    @Environment(OfflineDataUpdater.self) private var offlineUpdater

    private let packService = TilePackService()

    @State private var manifest: TileManifest?
    @State private var manifestError: String?
    @State private var isLoadingManifest = false
    @State private var installed: [InstalledRegion] = []
    @State private var downloadingID: String?
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?
    @State private var updateAllProgress: (completed: Int, total: Int)?
    @State private var speedCameraError: String?

    var body: some View {
        Form {
            policySection
            serverSection
            updatesSection
            installedSection
            speedCameraSection
            availableSection
        }
        .navigationTitle("Offline Routing")
        .toolbar {
            if !installed.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton().disabled(downloadingID != nil)
                }
            }
        }
        .task { await refresh() }
    }

    // MARK: Sections

    @ViewBuilder
    private var policySection: some View {
        Section {
            Label {
                Text("Routes are always computed on this device. Your location and destination never leave it.")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color(red: 0.0, green: 0.7, blue: 0.65))
            }
        } footer: {
            Text("Route planning requires a downloaded region and works in airplane mode.")
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("https://tiles.flckd.app", text: $tileServerURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                Task { await refresh() }
            } label: {
                HStack {
                    if isLoadingManifest { ProgressView().controlSize(.small) }
                    Text(isLoadingManifest ? "Checking..." : "Check Server")
                }
            }
            .disabled(isLoadingManifest)

            if let manifest {
                HStack {
                    Text("Data Release")
                    Spacer()
                    Text(manifest.releaseLabel).foregroundStyle(.secondary)
                }
                if let osmDate = manifest.osmDataDateLabel {
                    HStack {
                        Text("Map Data Date")
                        Spacer()
                        Text(osmDate).foregroundStyle(.secondary)
                    }
                }
            }
            if let manifestError {
                Text(manifestError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Tile Server")
        } footer: {
            Text("The server that provides road data and speed cameras.")
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section {
            Toggle("Update Automatically", isOn: Bindable(offlineUpdater).autoUpdate)
            HStack {
                Text("Last Checked")
                Spacer()
                if offlineUpdater.isUpdating {
                    ProgressView().controlSize(.small)
                } else {
                    Text(offlineUpdater.lastCheck?.formatted(.relative(presentation: .named)) ?? "Never")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(offlineUpdater.autoUpdate
                 ? "Checks once a day when the app opens and downloads updates. Regions download on Wi-Fi only."
                 : "Checks once a day when the app opens and tells you when an update is available.")
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if !installed.isEmpty {
            Section {
                ForEach(installed) { region in
                    installedRow(region)
                }
                .onDelete(perform: delete)
                if outdatedPacks.count > 1 || updateAllProgress != nil {
                    updateAllRow
                }
            } header: {
                Text("Downloaded Regions")
            } footer: {
                if !outdatedPacks.isEmpty {
                    Text("A newer data release is available for \(outdatedPacks.count) of your regions.")
                } else {
                    Text("Swipe a region, or tap Edit, to remove it and free the space. You can download it again at any time.")
                }
            }
        }
    }

    @ViewBuilder
    private var speedCameraSection: some View {
        Section {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speed Cameras")
                        if let summary = cameraStore.speedCameraFileSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "gauge.with.needle")
                }
                Spacer()
                if cameraStore.speedCameraFileSummary != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.0, green: 0.7, blue: 0.65))
                } else {
                    Text("Not downloaded")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if let speedCameraError {
                Text(speedCameraError).foregroundStyle(.red)
            } else {
                Text("Downloaded with your regions and updated with them. Everyone gets the same file.")
            }
        }
    }

    @ViewBuilder
    private func installedRow(_ region: InstalledRegion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(region.name)
                Text("\(ByteCountFormatter.string(fromByteCount: region.bytes, countStyle: .file)) · release \(region.releaseLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if downloadingID == region.id {
                downloadProgressLabel
            } else if let pack = outdatedPack(for: region), let manifest {
                Button("Update") {
                    download(pack, buildId: manifest.buildId)
                }
                .buttonStyle(.bordered)
                .disabled(downloadingID != nil || offlineUpdater.isUpdating)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.0, green: 0.7, blue: 0.65))
            }
        }
    }

    @ViewBuilder
    private var updateAllRow: some View {
        Button {
            updateAll()
        } label: {
            if let progress = updateAllProgress {
                Text("Updating \(min(progress.completed + 1, progress.total)) of \(progress.total)...")
            } else {
                Text("Update All Regions")
            }
        }
        .disabled(downloadingID != nil || offlineUpdater.isUpdating)
    }

    @ViewBuilder
    private var downloadProgressLabel: some View {
        ProgressView(value: downloadProgress)
            .frame(width: 80)
        Text("\(Int(downloadProgress * 100))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
    }

    private var outdatedPacks: [TilePack] {
        installed.compactMap { outdatedPack(for: $0) }
    }

    private func outdatedPack(for region: InstalledRegion) -> TilePack? {
        manifest?.packs.first { $0.id == region.id && $0.sha256 != region.sha256 }
    }

    @ViewBuilder
    private var availableSection: some View {
        Section {
            if let manifest {
                ForEach(manifest.packs) { pack in
                    availableRow(pack, buildId: manifest.buildId)
                }
            } else if !isLoadingManifest && manifestError == nil {
                Text("Check the server to see available regions.")
                    .foregroundStyle(.secondary)
            }
            if let downloadError {
                Text(downloadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Available Regions")
        } footer: {
            Text("Downloads use Wi-Fi sized files (100 MB+). Routing works in airplane mode once a region is installed.")
        }
    }

    @ViewBuilder
    private func availableRow(_ pack: TilePack, buildId: String) -> some View {
        let installedRegion = installed.first { $0.id == pack.id }
        let isCurrent = installedRegion?.sha256 == pack.sha256
        let isDownloading = downloadingID == pack.id

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                Text(ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDownloading {
                downloadProgressLabel
            } else if isCurrent {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(installedRegion != nil ? "Update" : "Download") {
                    download(pack, buildId: buildId)
                }
                .buttonStyle(.bordered)
                .disabled(downloadingID != nil || offlineUpdater.isUpdating)
            }
        }
    }

    // MARK: Actions

    @MainActor
    private func refresh() async {
        installed = RegionStore.installedRegions()
        isLoadingManifest = true
        manifestError = nil
        do {
            manifest = try await packService.fetchManifest()
            offlineUpdater.recordCheck()
            // This screen lists every update, so a banner saying one is
            // available would only repeat it.
            if case .available = offlineUpdater.notice { offlineUpdater.dismissNotice() }
        } catch {
            manifest = nil
            manifestError = error.localizedDescription
        }
        isLoadingManifest = false
        if !installed.isEmpty { await updateSpeedCameras() }
    }

    /// Rides on a manifest fetch or a pack download that is already
    /// happening, so it never adds a request at a time of its own.
    @MainActor
    private func updateSpeedCameras() async {
        guard let artifact = manifest?.speedCameras else { return }
        do {
            if try await packService.downloadSpeedCameras(artifact) {
                cameraStore.reloadSpeedCameraFile()
            }
            speedCameraError = nil
        } catch {
            speedCameraError = "Speed cameras: \(error.localizedDescription)"
        }
    }

    private func download(_ pack: TilePack, buildId: String) {
        downloadError = nil
        Task {
            do {
                try await install(pack, buildId: buildId)
            } catch {
                downloadError = error.localizedDescription
            }
            downloadingID = nil
        }
    }

    private func updateAll() {
        guard let manifest else { return }
        let packs = outdatedPacks
        guard !packs.isEmpty else { return }
        downloadError = nil
        updateAllProgress = (completed: 0, total: packs.count)
        Task {
            for (index, pack) in packs.enumerated() {
                updateAllProgress = (completed: index, total: packs.count)
                do {
                    try await install(pack, buildId: manifest.buildId)
                } catch {
                    downloadError = error.localizedDescription
                    break
                }
            }
            downloadingID = nil
            updateAllProgress = nil
        }
    }

    @MainActor
    private func install(_ pack: TilePack, buildId: String) async throws {
        downloadingID = pack.id
        downloadProgress = 0
        offlineUpdater.manualDownloadActive = true
        defer { offlineUpdater.manualDownloadActive = false }
        try await packService.downloadPack(pack, buildId: buildId) { fraction in
            Task { @MainActor in
                downloadProgress = fraction
            }
        }
        installed = RegionStore.installedRegions()
        await updateSpeedCameras()
    }

    private func delete(at offsets: IndexSet) {
        // Unmap before unlinking, or the space is not reclaimed.
        LocalValhallaEngine.shared.shutdown()
        for region in offsets.map({ installed[$0] }) {
            try? RegionStore.delete(region.id)
        }
        installed = RegionStore.installedRegions()
    }
}

#Preview {
    NavigationStack { OfflineRoutingView() }
        .environment(CameraStore())
        .environment(OfflineDataUpdater())
}
