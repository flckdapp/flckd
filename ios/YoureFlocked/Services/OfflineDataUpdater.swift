import Foundation
import Observation

/// What a newer catalog has that this device doesn't: installed regions whose
/// bytes changed, and the speed-camera file if it changed or is missing.
/// Compared by sha256, not release id, so an unchanged pack in a new release
/// isn't downloaded again.
struct UpdatePlan: Equatable {
    var packs: [TilePack]
    var speedCameras: SpeedCameraArtifact?

    var isEmpty: Bool { packs.isEmpty && speedCameras == nil }

    static func make(
        manifest: TileManifest,
        installed: [InstalledRegion],
        localSpeedCameraSHA: String?
    ) -> UpdatePlan {
        let packs = installed.compactMap { region in
            manifest.packs.first { $0.id == region.id && $0.sha256 != region.sha256 }
        }
        let cameras = manifest.speedCameras.flatMap { $0.sha256 == localSpeedCameraSHA ? nil : $0 }
        return UpdatePlan(packs: packs, speedCameras: cameras)
    }

    /// "Rhode Island and speed cameras", "4 regions", ...
    static func summary(packNames: [String], speedCameras: Bool) -> String {
        var items = packNames.count > 2 ? ["\(packNames.count) regions"] : packNames
        if speedCameras { items.append("speed cameras") }
        return items.formatted(.list(type: .and))
    }
}

/// Keeps downloaded offline data current: region packs and the speed-camera
/// file. When the app becomes active, at most once a day and only if
/// something has been downloaded, it reads the tile server's catalog, which
/// is the same for everyone. With automatic updates on it downloads what
/// changed (packs on Wi-Fi only) and says so; with them off it says an update
/// is available.
@Observable @MainActor
final class OfflineDataUpdater {

    static let autoUpdateKey = "autoUpdateOfflineData"
    static let lastCheckKey = "offlineDataLastCheck"
    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Notice: Equatable {
        case available(String)
        case downloaded(String)
    }

    var notice: Notice?
    private(set) var isUpdating = false
    private(set) var lastCheck: Date?
    /// Set by Offline Routing while the user is downloading, so the two never
    /// write the same pack at once.
    var manualDownloadActive = false

    var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Self.autoUpdateKey) }
    }

    @ObservationIgnored private var pending: (plan: UpdatePlan, buildId: String)?
    @ObservationIgnored private let packService: TilePackService
    @ObservationIgnored private let wifiOnlyPackService: TilePackService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installedRegions: () -> [InstalledRegion]
    @ObservationIgnored private let speedCameraFile: URL?

    init(
        packService: TilePackService = TilePackService(),
        wifiOnlyPackService: TilePackService = TilePackService(wifiOnly: true),
        defaults: UserDefaults = .standard,
        installedRegions: @escaping () -> [InstalledRegion] = RegionStore.installedRegions,
        speedCameraFile: URL? = SpeedCameraFile.defaultURL()
    ) {
        self.packService = packService
        self.wifiOnlyPackService = wifiOnlyPackService
        self.defaults = defaults
        self.installedRegions = installedRegions
        self.speedCameraFile = speedCameraFile
        self.autoUpdate = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        let last = defaults.double(forKey: Self.lastCheckKey)
        self.lastCheck = last > 0 ? Date(timeIntervalSince1970: last) : nil
    }

    nonisolated static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    func recordCheck(at date: Date = Date()) {
        lastCheck = date
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }

    /// Called whenever the app becomes active.
    func checkIfDue(cameraStore: CameraStore, now: Date = Date()) async {
        guard !isUpdating, !manualDownloadActive,
              Self.isDue(lastCheck: lastCheck, now: now) else { return }
        let installed = installedRegions()
        let localSHA = speedCameraFile.flatMap(SpeedCameraFile.sha256(of:))
        guard !installed.isEmpty || localSHA != nil else { return }

        isUpdating = true
        defer { isUpdating = false }
        guard let manifest = try? await packService.fetchManifest() else { return }
        recordCheck(at: now)

        let plan = UpdatePlan.make(manifest: manifest, installed: installed, localSpeedCameraSHA: localSHA)
        guard !plan.isEmpty else { return }
        if autoUpdate {
            await install(plan, buildId: manifest.buildId, cameraStore: cameraStore, packs: wifiOnlyPackService)
        } else {
            pending = (plan, manifest.buildId)
            notice = .available(Self.summary(plan.packs, plan.speedCameras != nil))
        }
    }

    /// The Update button on an "available" notice. The user asked, so any
    /// network will do.
    func installPending(cameraStore: CameraStore) async {
        guard let pending, !isUpdating, !manualDownloadActive else { return }
        isUpdating = true
        defer { isUpdating = false }
        notice = nil
        await install(pending.plan, buildId: pending.buildId, cameraStore: cameraStore, packs: packService)
    }

    func dismissNotice() {
        notice = nil
    }

    private func install(
        _ plan: UpdatePlan,
        buildId: String,
        cameraStore: CameraStore,
        packs service: TilePackService
    ) async {
        var cameraDone = false
        var cameraLeft: SpeedCameraArtifact?
        if let artifact = plan.speedCameras {
            do {
                if try await packService.downloadSpeedCameras(artifact, to: speedCameraFile) {
                    cameraStore.reloadSpeedCameraFile()
                }
                cameraDone = true
            } catch {
                cameraLeft = artifact
            }
        }

        var packsDone: [TilePack] = []
        var packsLeft: [TilePack] = []
        for pack in plan.packs {
            do {
                try await service.downloadPack(pack, buildId: buildId) { _ in }
                packsDone.append(pack)
            } catch {
                packsLeft.append(pack)
            }
        }

        let left = UpdatePlan(packs: packsLeft, speedCameras: cameraLeft)
        if !left.isEmpty {
            pending = (left, buildId)
            notice = .available(Self.summary(left.packs, left.speedCameras != nil))
        } else {
            pending = nil
            notice = .downloaded(Self.summary(packsDone, cameraDone))
        }
    }

    private static func summary(_ packs: [TilePack], _ speedCameras: Bool) -> String {
        UpdatePlan.summary(packNames: packs.map(\.name), speedCameras: speedCameras)
    }
}
