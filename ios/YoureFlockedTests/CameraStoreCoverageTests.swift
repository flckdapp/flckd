import XCTest
import CoreLocation
@testable import YoureFlocked

/// The store asks for a cell once and then stays quiet inside it.
/// All coordinates here are synthetic grid points, not places.
@MainActor
final class CameraStoreCoverageTests: XCTestCase {

    private let here = CLLocationCoordinate2D(latitude: 40.2, longitude: -75.7)
    private let overpassDir = TestDirectories.fresh()
    private let cdnDir = TestDirectories.fresh()

    override func setUp() {
        super.setUp()
        StubURLProtocol.recorder.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: overpassDir)
        try? FileManager.default.removeItem(at: cdnDir)
        super.tearDown()
    }

    private func makeStore(speedCameraFile: URL? = nil) -> CameraStore {
        let store = CameraStore(
            overpassService: OverpassService(session: StubURLProtocol.session(), cacheDirectory: overpassDir),
            cdnService: DeFlockCDNService(session: StubURLProtocol.session(), cacheDirectory: cdnDir),
            speedCameraFile: speedCameraFile
        )
        store.fetchFloor = 0
        store.speedCamerasEnabled = true
        return store
    }

    private var overpassBodies: [String] { StubURLProtocol.recorder.overpass.map(\.decodedBody) }

    func testFirstFetchAsksForTheContainingCellOnly() async {
        let store = makeStore()

        await store.fetchCameras(around: here)

        XCTAssertEqual(overpassBodies.count, 1)
        XCTAssertTrue(overpassBodies[0].contains("(40,-76,41,-75)"))
        XCTAssertEqual(store.lastFetchBounds, GridCell(lat: 40, lon: -76).bounds)
    }

    func testMovingWithinACellSendsNoFurtherRequest() async {
        let store = makeStore()
        await store.fetchCameras(around: here)

        for step in 1...20 {
            let moved = CLLocationCoordinate2D(
                latitude: here.latitude + Double(step) * 0.0027,
                longitude: here.longitude + Double(step) * 0.0036
            )
            await store.fetchCameras(around: moved)
        }

        XCTAssertEqual(overpassBodies.count, 1)
        XCTAssertEqual(store.cellsNeedingFetch([GridCell(containing: here)]), [])
    }

    func testCrossingACellEdgeFetchesTheNewCellOnce() async {
        let store = makeStore()
        await store.fetchCameras(around: here)
        let acrossTheEdge = CLLocationCoordinate2D(latitude: 41.1, longitude: here.longitude)

        await store.fetchCameras(around: acrossTheEdge)
        await store.fetchCameras(around: acrossTheEdge)

        XCTAssertEqual(overpassBodies.count, 2)
        XCTAssertTrue(overpassBodies[1].contains("(41,-76,42,-75)"))
    }

    func testCoverageExpiresWithTheCache() {
        let store = makeStore()
        let cell = GridCell(containing: here)
        let tooOld = Date().addingTimeInterval(OverpassService.cacheTTL + 1)

        XCTAssertEqual(store.cellsNeedingFetch([cell]), [cell])
        XCTAssertEqual(store.cellsNeedingFetch([cell], now: tooOld), [cell])
    }

    func testSpeedCamerasOffSendsNoOverpassRequest() async {
        let store = makeStore()
        store.speedCamerasEnabled = false

        await store.fetchCameras(around: here)

        XCTAssertEqual(overpassBodies.count, 0)
        XCTAssertGreaterThan(StubURLProtocol.recorder.cdn.count, 0, "ALPRs are still loaded")
    }

    func testTurningSpeedCamerasBackOnRefetchesTheCell() async {
        let store = makeStore()
        store.speedCamerasEnabled = false
        await store.fetchCameras(around: here)

        store.speedCamerasEnabled = true
        await store.fetchCameras(around: here)

        XCTAssertEqual(overpassBodies.count, 1)
    }

    func testLaunchInsideACachedCellSendsNoOverpassRequest() async {
        await makeStore().fetchCameras(around: here)

        await makeStore().fetchCameras(around: here)

        XCTAssertEqual(overpassBodies.count, 1)
    }

    func testVisibleRegionInsideOneCellAsksForThatCellOnly() async {
        let store = makeStore()

        await store.fetchCameras(covering: BoundingBox.around(center: here, radiusKm: 5))

        XCTAssertEqual(overpassBodies.count, 1)
        XCTAssertTrue(overpassBodies[0].contains("(40,-76,41,-75)"))
    }

    private func speedFile(_ cameras: [(id: Int64, lat: Double, lon: Double)]) -> URL {
        let url = overpassDir.appendingPathComponent("speed-cameras-\(UUID().uuidString).json")
        SpeedCameraFixture.write(cameras, to: url)
        return url
    }

    func testWithTheDownloadedFileOverpassIsNeverAskedForSpeedCameras() async {
        let store = makeStore(speedCameraFile: speedFile([(1, 40.5, -75.5), (2, 41.5, -75.5)]))

        await store.fetchCameras(around: here)
        XCTAssertEqual(store.cameras.map(\.osmID), [1], "only the cell's own cameras")
        await store.fetchCameras(around: CLLocationCoordinate2D(latitude: 41.1, longitude: here.longitude))

        XCTAssertEqual(overpassBodies.count, 0)
        XCTAssertEqual(Set(store.cameras.map(\.osmID)), [1, 2])
        XCTAssertEqual(store.speedCameraSource, "Region download")
    }

    func testRoutePlanningWithTheFileSendsNothingToOverpass() async throws {
        let store = makeStore(speedCameraFile: speedFile([(1, 40.5, -75.5)]))
        let corridor = BoundingBox(south: 40.2, west: -75.7, north: 41.3, east: -74.9)

        let cameras = try await store.fetchFromBestSource(in: corridor)

        XCTAssertEqual(overpassBodies.count, 0)
        XCTAssertEqual(cameras.map(\.osmID), [1])
    }

    func testTurningSpeedCamerasOffRemovesThemFromMapAndAlerts() async {
        let store = makeStore(speedCameraFile: speedFile([(1, 40.5, -75.5)]))
        await store.fetchCameras(around: here)
        XCTAssertEqual(store.cameras.count, 1)

        store.speedCamerasEnabled = false
        await store.fetchCameras(around: here)

        XCTAssertEqual(store.cameras.count, 0)
        XCTAssertEqual(store.checkProximity(location: CLLocation(latitude: 40.5, longitude: -75.5), alertRadius: 500).count, 0)
    }

    func testWhenTheCDNIsDownSpeedCamerasStillComeFromTheFile() async {
        StubURLProtocol.recorder.reset { request in
            request.host.contains("overpass") ? (200, StubURLProtocol.emptyOverpass) : (503, Data())
        }
        let store = makeStore(speedCameraFile: speedFile([(1, 40.5, -75.5)]))

        await store.fetchCameras(around: here)

        XCTAssertEqual(overpassBodies.count, 1, "ALPRs fall back to Overpass")
        XCTAssertTrue(overpassBodies[0].contains("man_made"))
        XCTAssertEqual(store.cameras.map(\.osmID), [1])
    }

    func testANewFileReplacesTheOldCameras() async {
        let file = speedFile([(1, 40.5, -75.5)])
        let store = makeStore(speedCameraFile: file)
        await store.fetchCameras(around: here)

        SpeedCameraFixture.write([(3, 40.6, -75.5)], to: file)
        store.reloadSpeedCameraFile()
        await store.fetchCameras(around: here)

        XCTAssertEqual(store.cameras.map(\.osmID), [3])
        XCTAssertEqual(overpassBodies.count, 0)
    }

    func testRouteCorridorSendsOnlyWholeCells() async throws {
        let store = makeStore()
        let origin = CLLocationCoordinate2D(latitude: 40.2 + 0.0123, longitude: -75.7 + 0.0456)
        let destination = CLLocationCoordinate2D(latitude: 41.3 + 0.0789, longitude: -74.9 + 0.0012)
        let corridor = BoundingBox(
            south: min(origin.latitude, destination.latitude),
            west: min(origin.longitude, destination.longitude),
            north: max(origin.latitude, destination.latitude),
            east: max(origin.longitude, destination.longitude)
        )

        _ = try await store.fetchFromBestSource(in: corridor)

        XCTAssertEqual(overpassBodies.count, 4)
        for body in overpassBodies {
            XCTAssertNotNil(body.range(of: #"\(-?\d+,-?\d+,-?\d+,-?\d+\)"#, options: .regularExpression))
            XCTAssertNil(body.range(of: #"\d\.\d"#, options: .regularExpression),
                         "origin/destination precision leaked: \(body)")
        }
    }
}
