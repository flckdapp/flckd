import XCTest
@testable import YoureFlocked

final class UpdatePlanTests: XCTestCase {

    private func pack(_ id: String, sha: String) -> TilePack {
        TilePack(id: id, name: id.capitalized, iso3166: nil, bytes: 1, sha256: sha, partBytes: nil, parts: [])
    }

    private func region(_ id: String, sha: String, buildId: String = "r1") -> InstalledRegion {
        InstalledRegion(id: id, name: id.capitalized, buildId: buildId, bytes: 1, sha256: sha,
                        valhallaVersion: "3.6.3", installedAt: Date())
    }

    private func manifest(_ packs: [TilePack], cameras: SpeedCameraArtifact? = nil) -> TileManifest {
        TileManifest(schema: 1, buildId: "r2", valhallaVersion: "3.6.3", osmDataDate: nil,
                     totalBytes: nil, packs: packs, speedCameras: cameras)
    }

    func testOnlyInstalledRegionsWhoseBytesChangedAreUpdated() {
        let plan = UpdatePlan.make(
            manifest: manifest([pack("alpha", sha: "new"), pack("beta", sha: "same"), pack("gamma", sha: "x")]),
            installed: [region("alpha", sha: "old"), region("beta", sha: "same")],
            localSpeedCameraSHA: nil
        )

        XCTAssertEqual(plan.packs.map(\.id), ["alpha"])
    }

    func testSpeedCamerasAreUpdatedWhenChangedOrMissing() {
        let artifact = SpeedCameraArtifact(path: "/v1/cameras/a.json", bytes: 1, sha256: "a", count: 1, osmDataDate: nil)

        XCTAssertEqual(UpdatePlan.make(manifest: manifest([], cameras: artifact), installed: [], localSpeedCameraSHA: nil).speedCameras, artifact)
        XCTAssertEqual(UpdatePlan.make(manifest: manifest([], cameras: artifact), installed: [], localSpeedCameraSHA: "b").speedCameras, artifact)
        XCTAssertNil(UpdatePlan.make(manifest: manifest([], cameras: artifact), installed: [], localSpeedCameraSHA: "a").speedCameras)
        XCTAssertTrue(UpdatePlan.make(manifest: manifest([]), installed: [], localSpeedCameraSHA: "a").isEmpty)
    }

    func testSummaryNamesWhatChanged() {
        XCTAssertEqual(UpdatePlan.summary(packNames: ["Alpha"], speedCameras: true), "Alpha and speed cameras")
        XCTAssertEqual(UpdatePlan.summary(packNames: [], speedCameras: true), "speed cameras")
        XCTAssertEqual(UpdatePlan.summary(packNames: ["A", "B", "C", "D"], speedCameras: false), "4 regions")
    }

    func testACheckIsDueOncePerDay() {
        let now = Date()

        XCTAssertTrue(OfflineDataUpdater.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(OfflineDataUpdater.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(OfflineDataUpdater.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
    }

    func testALPRSnapshotDateComesFromTheTileVersion() async throws {
        let dir = TestDirectories.fresh()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("[]".utf8).write(to: dir.appendingPathComponent("20_-100.json"))
        try "1700000000".write(to: dir.appendingPathComponent("20_-100.version"), atomically: true, encoding: .utf8)
        try "1600000000".write(to: dir.appendingPathComponent("20_-80.version"), atomically: true, encoding: .utf8)

        let status = await DeFlockCDNService(session: StubURLProtocol.session(), cacheDirectory: dir).status()

        XCTAssertEqual(status.snapshotDate, Date(timeIntervalSince1970: 1_700_000_000))
    }
}

/// The daily check against a stubbed tile server. The installed region's
/// bytes match the catalog, so only the speed-camera file changes and
/// nothing is written into the real region store.
@MainActor
final class OfflineDataUpdaterTests: XCTestCase {

    private let dir = TestDirectories.fresh()
    private let defaults = UserDefaults(suiteName: "flckd-tests-\(UUID().uuidString)")!
    private let cameraData = SpeedCameraFixture.data([(1, 40.5, -75.5)])
    private var cameraFile: URL { dir.appendingPathComponent("speed-cameras.json") }

    override func setUp() {
        super.setUp()
        serve(cameraStatus: 200)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    nonisolated private func serve(cameraStatus: Int) {
        let artifact = SpeedCameraFixture.artifact(for: cameraData)
        let manifest = Data("""
        {"schema":1,"build_id":"r2","valhalla_version":"3.6.3",
         "packs":[{"id":"test","name":"Test","bytes":1,"sha256":"same","parts":[]}],
         "speed_cameras":{"path":"\(artifact.path)","bytes":\(artifact.bytes),"sha256":"\(artifact.sha256)"}}
        """.utf8)
        let cameras = cameraData
        StubURLProtocol.recorder.reset { request in
            if request.url.path.hasSuffix("/v1/manifest.json") { return (200, manifest) }
            if request.url.path.hasPrefix("/v1/cameras/") { return (cameraStatus, cameraStatus == 200 ? cameras : Data()) }
            return (404, Data())
        }
    }

    private func makeUpdater(autoUpdate: Bool, installed: [InstalledRegion]? = nil) -> OfflineDataUpdater {
        defaults.set(autoUpdate, forKey: OfflineDataUpdater.autoUpdateKey)
        let regions = installed ?? [InstalledRegion(id: "test", name: "Test", buildId: "r1", bytes: 1, sha256: "same",
                                                    valhallaVersion: "3.6.3", installedAt: Date())]
        return OfflineDataUpdater(
            packService: TilePackService(session: StubURLProtocol.session()),
            wifiOnlyPackService: TilePackService(session: StubURLProtocol.session()),
            defaults: defaults,
            installedRegions: { regions },
            speedCameraFile: cameraFile
        )
    }

    private func makeStore() -> CameraStore {
        CameraStore(
            overpassService: OverpassService(session: StubURLProtocol.session(), cacheDirectory: dir),
            cdnService: DeFlockCDNService(session: StubURLProtocol.session(), cacheDirectory: dir),
            speedCameraFile: cameraFile
        )
    }

    private var cameraRequests: Int {
        StubURLProtocol.recorder.all.filter { $0.url.path.hasPrefix("/v1/cameras/") }.count
    }

    func testAutomaticUpdateDownloadsAndSaysSo() async throws {
        let updater = makeUpdater(autoUpdate: true)
        let store = makeStore()

        await updater.checkIfDue(cameraStore: store)

        XCTAssertEqual(try Data(contentsOf: cameraFile), cameraData)
        XCTAssertEqual(updater.notice, .downloaded("speed cameras"))
        XCTAssertNotNil(updater.lastCheck)
        XCTAssertEqual(store.speedCameraSource, "Region download")
    }

    func testWithAutomaticUpdateOffItOnlySaysAnUpdateIsAvailable() async throws {
        let updater = makeUpdater(autoUpdate: false)
        let store = makeStore()

        await updater.checkIfDue(cameraStore: store)

        XCTAssertEqual(updater.notice, .available("speed cameras"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cameraFile.path))
        XCTAssertEqual(cameraRequests, 0)

        await updater.installPending(cameraStore: store)

        XCTAssertEqual(try Data(contentsOf: cameraFile), cameraData)
        XCTAssertEqual(updater.notice, .downloaded("speed cameras"))
    }

    func testNoSecondCheckTheSameDay() async {
        let updater = makeUpdater(autoUpdate: false)
        let store = makeStore()
        await updater.checkIfDue(cameraStore: store)
        StubURLProtocol.recorder.reset()

        await updater.checkIfDue(cameraStore: store, now: Date().addingTimeInterval(3600))

        XCTAssertEqual(StubURLProtocol.recorder.all.count, 0)
    }

    func testNothingDownloadedMeansNoCheckAtAll() async {
        let updater = makeUpdater(autoUpdate: true, installed: [])

        await updater.checkIfDue(cameraStore: makeStore())

        XCTAssertEqual(StubURLProtocol.recorder.all.count, 0)
        XCTAssertNil(updater.lastCheck)
    }

    func testAFailedDownloadBecomesAnUpdateAvailableNotice() async {
        serve(cameraStatus: 500)
        let updater = makeUpdater(autoUpdate: true)

        await updater.checkIfDue(cameraStore: makeStore())

        XCTAssertEqual(updater.notice, .available("speed cameras"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cameraFile.path))
    }
}
