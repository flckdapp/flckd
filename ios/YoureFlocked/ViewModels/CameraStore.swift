import Foundation
import CoreLocation
import Observation
import SwiftData

enum AlertMode: String, CaseIterable {
    case nearCamera = "near"
    case inFieldOfView = "fov"

    var displayName: String {
        switch self {
        case .nearCamera: return "Near Camera"
        case .inFieldOfView: return "In Field of View"
        }
    }

    var description: String {
        switch self {
        case .nearCamera: return "Alert when within range of any camera"
        case .inFieldOfView: return "Alert only when inside a camera's viewing angle"
        }
    }
}

// MARK: - Camera Store

/// Central data store for surveillance cameras.
///
/// Coordinates between the network sources (DeFlock CDN, Overpass) and
/// SwiftData (local cache). Provides the camera list to views and triggers
/// proximity checks.
///
/// Every network fetch is for whole-degree grid cells, never for a box
/// around the user. A cell that has been loaded is not asked for again
/// until it expires, so the request rate while driving is one per cell
/// boundary crossed, not one per position update.
@Observable
final class CameraStore {

    // MARK: - State

    var cameras: [SurveillanceCamera] = []
    var pendingCameraIDs: Set<Int64> = []
    var isLoading: Bool = false
    var lastError: Error?

    /// The union of the cells the last completed fetch covered.
    var lastFetchBounds: BoundingBox?

    var nearbyCameras: [(camera: SurveillanceCamera, distance: CLLocationDistance)] = []

    var pendingCount: Int { pendingCameraIDs.count }

    // MARK: - Configuration

    /// The key Settings' slider writes through `@AppStorage`. Named so the
    /// slider and the seeding below can't drift apart on a typo.
    static let fetchRadiusKey = "fetchRadius"

    /// The key Settings' "Show Speed Cameras" toggle writes.
    static let showSpeedCamerasKey = "showSpeedCameras"

    /// Radius (km) around the user's location the map keeps loaded. Sets how
    /// far from a cell edge the neighbouring cell is requested too.
    var fetchRadiusKm: Double = 5.0

    /// When off, speed cameras are neither loaded nor kept, so they leave the
    /// map and the alerts, and Overpass is never asked for them. Hiding them
    /// on the map used to leave the query running underneath.
    var speedCamerasEnabled: Bool = true {
        didSet {
            guard speedCamerasEnabled != oldValue else { return }
            if !speedCamerasEnabled { cameras.removeAll { $0.surveillanceType == .speedCamera } }
            coverage.removeAll()
        }
    }

    /// Hard floor between fetches. A bug guard against a runaway caller,
    /// not the throttle: suppression is by cell coverage.
    var fetchFloor: TimeInterval = 5

    // MARK: - Private

    private let overpassService: OverpassService
    private let cdnService: DeFlockCDNService
    private var lastFetchTime: Date?

    /// The speed-camera file downloaded with a region pack. While it exists,
    /// speed cameras come from it and Overpass is only the fallback for when
    /// the DeFlock CDN is down. Read lazily: it is a few hundred kilobytes.
    private let speedCameraFile: URL?
    @ObservationIgnored private var speedCameraFileRead = false
    @ObservationIgnored private var fileSpeedCameras: SpeedCameraFile.Contents?
    private var speedCameraFileVersion = 0

    /// Cells in memory and when they were loaded. A cell fetched within
    /// `OverpassService.cacheTTL` is covered and is not requested again.
    private var coverage: [GridCell: Date] = [:]

    // MARK: - Data Source Status (for Settings)

    enum CameraDataSource: String {
        case deflockCDN = "DeFlock CDN"
        case overpass = "OpenStreetMap (Overpass)"
    }

    /// Which source served the last successful ALPR fetch.
    var lastALPRSource: CameraDataSource?

    var speedCameraSource: String {
        guard loadSpeedCameraFile() != nil else { return CameraDataSource.overpass.rawValue }
        return "Region download"
    }

    var speedCameraDataDate: String? { loadSpeedCameraFile()?.osmDataDate }
    /// When the last successful camera fetch completed.
    var lastFetchDate: Date?
    /// Whether the last speed-camera (Overpass) fetch succeeded.
    var speedCamerasAvailable: Bool = true

    @MainActor
    func cdnStatus() async -> DeFlockCDNService.Status {
        await cdnService.status()
    }

    @MainActor
    func clearCDNCache() async {
        await cdnService.clearCache()
        await overpassService.clearCache()
        coverage.removeAll()
    }

    /// When set, every successful fetch is written through to the SwiftData
    /// cache so the app warm-starts with last-seen cameras even when the
    /// network is unreachable at launch. Persistence runs debounced on a
    /// background context, off the MainActor.
    var cacheContainer: ModelContainer?

    /// In-flight debounced background persist.
    private var persistTask: Task<Void, Never>?

    /// Soft cap on the in-memory store. Rendering is separately capped, but
    /// an unbounded store makes every merge/persist/proximity pass slower.
    private let maxStoredCameras = 15_000

    /// True when the store is at its soft cap and the farthest cameras are
    /// being evicted as new areas load. The count badge shows "N+" in this
    /// state so the plateau reads as intentional, not frozen.
    var isAtStoreCap: Bool { cameras.count >= maxStoredCameras }

    /// Pending backoff retry after a failed fetch.
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private let maxRetryAttempts = 3

    // MARK: - Lifecycle

    init(
        overpassService: OverpassService = OverpassService(),
        cdnService: DeFlockCDNService = DeFlockCDNService(),
        speedCameraFile: URL? = SpeedCameraFile.defaultURL()
    ) {
        self.overpassService = overpassService
        self.cdnService = cdnService
        self.speedCameraFile = speedCameraFile

        // Settings writes the slider through `@AppStorage` and pushes it here
        // on change. Nothing read it back, so every launch reverted to the
        // default while Settings still displayed the stored value: the setting
        // appeared to work and silently didn't survive a relaunch.
        // `double(forKey:)` yields 0 when the key was never written.
        let stored = UserDefaults.standard.double(forKey: Self.fetchRadiusKey)
        if stored > 0 { fetchRadiusKm = stored }
        if let show = UserDefaults.standard.object(forKey: Self.showSpeedCamerasKey) as? Bool {
            speedCamerasEnabled = show
        }
    }

    // MARK: - Speed Camera File

    private func loadSpeedCameraFile() -> SpeedCameraFile.Contents? {
        _ = speedCameraFileVersion
        if !speedCameraFileRead {
            speedCameraFileRead = true
            fileSpeedCameras = speedCameraFile.flatMap(SpeedCameraFile.load(from:))
        }
        return fileSpeedCameras
    }

    /// Call after a new speed-camera file is installed. Drops the speed
    /// cameras held in memory and forgets which cells are loaded, so the next
    /// fetch takes speed cameras from the new file: one deleted from the map
    /// disappears rather than lingering from the old one.
    func reloadSpeedCameraFile() {
        speedCameraFileRead = false
        fileSpeedCameras = nil
        speedCameraFileVersion += 1
        cameras.removeAll { $0.surveillanceType == .speedCamera }
        coverage.removeAll()
    }

    private func fileSpeedCameras(in cell: GridCell) -> [SurveillanceCamera]? {
        guard let contents = loadSpeedCameraFile() else { return nil }
        let bounds = cell.bounds
        return contents.cameras.filter { bounds.contains($0.coordinate) }
    }

    // MARK: - Data Fetching

    /// Which of the given cells still need a fetch. Pure, so the suppression
    /// rule can be tested without a network.
    func cellsNeedingFetch(_ cells: [GridCell], now: Date = Date()) -> [GridCell] {
        cells.filter { cell in
            guard let loaded = coverage[cell] else { return true }
            return now.timeIntervalSince(loaded) >= OverpassService.cacheTTL
        }
    }

    /// Fetch the cell the user is in. Used by the proximity engine on every
    /// location update; a no-op until the user crosses into a new cell.
    @MainActor
    func fetchCameras(around coordinate: CLLocationCoordinate2D) async {
        await fetch(cells: [GridCell(containing: coordinate)])
    }

    /// Fetch every cell a box intersects. Used by the map for the visible
    /// region; a box inside one cell asks for that cell only.
    @MainActor
    func fetchCameras(covering bounds: BoundingBox) async {
        await fetch(cells: GridCell.covering(bounds))
    }

    @MainActor
    private func fetch(cells: [GridCell]) async {
        let needed = cellsNeedingFetch(cells)
        guard !needed.isEmpty else { return }

        if let lastFetch = lastFetchTime, Date().timeIntervalSince(lastFetch) < fetchFloor {
            return
        }

        // A user-driven fetch supersedes any pending backoff retry.
        retryTask?.cancel()

        isLoading = true
        lastError = nil

        do {
            let fetched = try await fetchFromBestSource(cells: needed)
            mergeCameras(fetched)
            let now = Date()
            for cell in needed { coverage[cell] = now }
            lastFetchBounds = BoundingBox.union(cells.map(\.bounds))
            lastFetchTime = now
            lastFetchDate = now
            retryAttempt = 0
            schedulePersist()
        } catch {
            lastError = error
            scheduleRetry(cells: cells)
        }

        isLoading = false
    }

    /// Fetch cameras for every cell a box intersects, using the best
    /// available source. Does not touch coverage: callers that keep their
    /// own list (route planning) use this directly.
    @MainActor
    func fetchFromBestSource(in bounds: BoundingBox) async throws -> [SurveillanceCamera] {
        try await fetchFromBestSource(cells: GridCell.covering(bounds))
    }

    @MainActor
    private func fetchFromBestSource(cells: [GridCell]) async throws -> [SurveillanceCamera] {
        var result: [SurveillanceCamera] = []
        for cell in cells {
            result += try await fetchFromBestSource(cell: cell)
        }
        return result
    }

    /// ALPRs come from DeFlock's CDN (hourly bulk snapshots, disk-cached).
    /// Speed cameras come from the file downloaded with a region pack, or
    /// from Overpass when there is no file yet. If the CDN fails entirely,
    /// the other camera types fall back to one Overpass query for the cell.
    @MainActor
    private func fetchFromBestSource(cell: GridCell) async throws -> [SurveillanceCamera] {
        // Hoist the actor references so the async-let child tasks capture
        // only Sendable values, not non-Sendable `self`.
        let cdn = cdnService
        let overpass = overpassService
        let wantSpeed = speedCamerasEnabled
        let fromFile = wantSpeed ? fileSpeedCameras(in: cell) : nil
        do {
            guard wantSpeed, fromFile == nil else {
                let alprs = try await cdn.fetchALPRCameras(in: cell.bounds)
                lastALPRSource = .deflockCDN
                if fromFile != nil { speedCamerasAvailable = true }
                return alprs + (fromFile ?? [])
            }

            async let alprTask = cdn.fetchALPRCameras(in: cell.bounds)
            async let speedTask = overpass.speedCameras(in: cell)

            let alprs = try await alprTask
            lastALPRSource = .deflockCDN

            // Speed cameras are additive; an Overpass outage should not
            // discard a successful CDN result.
            if let speed = try? await speedTask {
                speedCamerasAvailable = true
                return alprs + speed
            }
            speedCamerasAvailable = false
            return alprs
        } catch {
            // CDN down: single combined Overpass query. Speed cameras still
            // come from the file when there is one.
            let fetched = try await overpass.allCameras(in: cell)
            lastALPRSource = .overpass
            speedCamerasAvailable = true
            guard wantSpeed else { return fetched.filter { $0.surveillanceType != .speedCamera } }
            guard let fromFile else { return fetched }
            return fetched.filter { $0.surveillanceType != .speedCamera } + fromFile
        }
    }

    /// Retry a failed fetch with exponential backoff (5s, 10s, 20s), so a
    /// launch during an outage recovers without waiting for the user to pan.
    @MainActor
    private func scheduleRetry(cells: [GridCell]) {
        guard retryAttempt < maxRetryAttempts else { return }
        let delay = 5.0 * pow(2.0, Double(retryAttempt))
        retryAttempt += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            // Clear the handle first so fetch's cancel() above doesn't
            // cancel this already-running task (which would abort its own
            // URLSession request).
            self.retryTask = nil
            await self.fetch(cells: cells)
        }
    }

    // MARK: - Proximity

    func checkProximity(
        location: CLLocation,
        alertRadius: CLLocationDistance,
        alertMode: AlertMode = .nearCamera
    ) -> [(camera: SurveillanceCamera, distance: CLLocationDistance)] {
        // Bounding-box prefilter. Building a CLLocation and computing a
        // haversine distance for thousands of cameras on every location
        // update (about once a second) is measurable main-thread work; two
        // abs() compares reject most of them first.
        let latWindow = alertRadius * 1.5 / 111_000.0
        let lonWindow = latWindow / max(0.2, cos(location.coordinate.latitude * .pi / 180))
        let nearby = cameras.compactMap { camera -> (camera: SurveillanceCamera, distance: CLLocationDistance)? in
            guard abs(camera.latitude - location.coordinate.latitude) <= latWindow,
                  abs(camera.longitude - location.coordinate.longitude) <= lonWindow else { return nil }
            let cameraLocation = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
            let distance = location.distance(from: cameraLocation)
            guard distance <= alertRadius else { return nil }

            if alertMode == .inFieldOfView {
                guard camera.isInFieldOfView(from: location.coordinate) else { return nil }
            }

            return (camera: camera, distance: distance)
        }
        .sorted { $0.distance < $1.distance }

        nearbyCameras = nearby
        return nearby
    }

    // MARK: - Data Management

    /// Merge new cameras with existing, deduplicating by OSM ID
    private func mergeCameras(_ newCameras: [SurveillanceCamera]) {
        var cameraMap = Dictionary(cameras.map { ($0.osmID, $0) }, uniquingKeysWith: { _, new in new })
        for camera in newCameras where speedCamerasEnabled || camera.surveillanceType != .speedCamera {
            cameraMap[camera.osmID] = camera
        }
        var merged = Array(cameraMap.values)
        // Evict the cameras farthest from the most recent fetch area when
        // a long pan session grows the store past the cap, keeping memory
        // and per-update scan costs bounded.
        if merged.count > maxStoredCameras, let ref = lastFetchBounds {
            let cLat = (ref.north + ref.south) / 2
            let cLon = (ref.east + ref.west) / 2
            merged.sort {
                let a = pow($0.latitude - cLat, 2) + pow($0.longitude - cLon, 2)
                let b = pow($1.latitude - cLat, 2) + pow($1.longitude - cLon, 2)
                return a < b
            }
            merged.removeLast(merged.count - maxStoredCameras)
        }
        cameras = merged
    }

    /// Debounced background write-through of the in-memory cameras to
    /// SwiftData. Clearing and re-inserting thousands of rows on the
    /// MainActor stalls the UI for seconds, so the work runs on a detached
    /// task with its own context.
    @MainActor
    func schedulePersist() {
        guard let container = cacheContainer else { return }
        persistTask?.cancel()
        let snapshot = cameras
        let pending = pendingCameraIDs
        persistTask = Task.detached(priority: .utility) {
            // Debounce: rapid pan-fetches coalesce into one write.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<CachedCamera>()
            if let cached = try? context.fetch(descriptor) {
                for row in cached { context.delete(row) }
            }
            for camera in snapshot {
                let cached = CachedCamera(from: camera)
                // CachedCamera(from:) defaults isPendingUpload to false;
                // restore it so pending uploads survive relaunches.
                cached.isPendingUpload = pending.contains(camera.osmID)
                context.insert(cached)
            }
            try? context.save()
        }
    }

    /// Load cached cameras off the main thread. Fetching and converting
    /// thousands of SwiftData rows on the MainActor adds seconds to cold start.
    @MainActor
    func loadFromCache(container: ModelContainer) async {
        guard cameras.isEmpty else { return }
        let loaded: ([SurveillanceCamera], Set<Int64>) = await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<CachedCamera>()
            guard let cached = try? context.fetch(descriptor) else { return ([], []) }
            let cams = cached.map { $0.toSurveillanceCamera() }
            let pending = Set(cached.filter { $0.isPendingUpload }.map { $0.osmID })
            return (cams, pending)
        }.value
        guard cameras.isEmpty else { return }
        mergeCameras(loaded.0)
        pendingCameraIDs.formUnion(loaded.1)
    }

    @MainActor
    func downloadArea(
        around coordinate: CLLocationCoordinate2D,
        radiusKm: Double,
        context: ModelContext
    ) async throws -> Int {
        let cells = GridCell.covering(BoundingBox.around(center: coordinate, radiusKm: radiusKm))
        let fetched = try await fetchFromBestSource(cells: cells)
        mergeCameras(fetched)
        let now = Date()
        for cell in cells { coverage[cell] = now }
        lastFetchBounds = BoundingBox.union(cells.map(\.bounds))
        lastFetchTime = now
        cacheContainer = context.container
        schedulePersist()
        return fetched.count
    }

    @MainActor
    func clearCache(context: ModelContext) {
        let descriptor = FetchDescriptor<CachedCamera>()
        guard let cached = try? context.fetch(descriptor) else { return }
        for camera in cached {
            context.delete(camera)
        }
        try? context.save()
    }

    @MainActor
    func cacheStats(context: ModelContext) -> (count: Int, sizeBytes: Int64) {
        let descriptor = FetchDescriptor<CachedCamera>()
        guard let cached = try? context.fetch(descriptor) else { return (0, 0) }

        let sizeBytes = cached.reduce(into: Int64(0)) { total, camera in
            total += Int64(MemoryLayout<Int64>.size)
            total += Int64(MemoryLayout<Double>.size * 2)
            total += Int64(camera.surveillanceType.utf8.count)
            total += Int64(camera.manufacturer?.utf8.count ?? 0)
            total += Int64(camera.operatorName?.utf8.count ?? 0)
            total += Int64(camera.cameraMount?.utf8.count ?? 0)
            total += Int64(camera.surveillanceZone?.utf8.count ?? 0)
            total += Int64(camera.tagsJSON?.count ?? 0)
            total += Int64(camera.userNotes?.utf8.count ?? 0)
            total += Int64(camera.profileID?.utf8.count ?? 0)
        }
        return (cached.count, sizeBytes)
    }

    func addPendingCamera(_ camera: SurveillanceCamera) {
        cameras.append(camera)
        pendingCameraIDs.insert(camera.osmID)
    }

    func isPending(_ camera: SurveillanceCamera) -> Bool {
        pendingCameraIDs.contains(camera.osmID)
    }
}
