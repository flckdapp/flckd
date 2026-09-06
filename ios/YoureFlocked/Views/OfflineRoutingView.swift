import SwiftUI

// MARK: - Offline Routing Settings

/// Settings screen for on-device routing: tile server, downloaded regions,
/// and the offline-only policy. Reached from SettingsView.
struct OfflineRoutingView: View {
    @AppStorage("tileServerURL") private var tileServerURL: String = TilePackService.defaultServerURL

    private let packService = TilePackService()

    @State private var manifest: TileManifest?
    @State private var manifestError: String?
    @State private var isLoadingManifest = false
    @State private var installed: [InstalledRegion] = []
    @State private var downloadingID: String?
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?

    var body: some View {
        Form {
            policySection
            serverSection
            installedSection
            availableSection
        }
        .navigationTitle("Offline Routing")
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
                    Text(manifest.buildId).foregroundStyle(.secondary)
                }
                if let osmDate = manifest.osmDataDate {
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
            Text("The server that provides downloadable road data. Regions download once and update monthly.")
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if !installed.isEmpty {
            Section("Downloaded Regions") {
                ForEach(installed) { region in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(region.name)
                            Text("\(ByteCountFormatter.string(fromByteCount: region.bytes, countStyle: .file)) · release \(region.buildId)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.0, green: 0.7, blue: 0.65))
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            delete(region)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
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
        let isCurrent = installedRegion?.buildId == buildId
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
                ProgressView(value: downloadProgress)
                    .frame(width: 80)
                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            } else if isCurrent {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(installedRegion != nil ? "Update" : "Download") {
                    download(pack, buildId: buildId)
                }
                .buttonStyle(.bordered)
                .disabled(downloadingID != nil)
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
        } catch {
            manifest = nil
            manifestError = error.localizedDescription
        }
        isLoadingManifest = false
    }

    private func download(_ pack: TilePack, buildId: String) {
        downloadingID = pack.id
        downloadProgress = 0
        downloadError = nil
        Task {
            do {
                try await packService.downloadPack(pack, buildId: buildId) { fraction in
                    Task { @MainActor in
                        downloadProgress = fraction
                    }
                }
                await MainActor.run {
                    downloadingID = nil
                    installed = RegionStore.installedRegions()
                }
            } catch {
                await MainActor.run {
                    downloadingID = nil
                    downloadError = error.localizedDescription
                }
            }
        }
    }

    private func delete(_ region: InstalledRegion) {
        // Unmap before unlinking, or the space is not reclaimed.
        LocalValhallaEngine.shared.shutdown()
        try? RegionStore.delete(region.id)
        installed = RegionStore.installedRegions()
    }
}

#Preview {
    NavigationStack { OfflineRoutingView() }
}
