import XCTest
import CoreLocation
import CryptoKit
@testable import YoureFlocked

/// Builds a speed-camera file in the server's format. All coordinates are
/// synthetic grid points, not places.
enum SpeedCameraFixture {
    static func data(_ cameras: [(id: Int64, lat: Double, lon: Double)]) -> Data {
        let entries = cameras.map { #"{"id":\#($0.id),"lat":\#($0.lat),"lon":\#($0.lon),"tags":{"highway":"speed_camera"}}"# }
        return Data(#"{"schema":1,"osm_data_date":"2026-10-28","license":"ODbL-1.0","count":\#(cameras.count),"cameras":[\#(entries.joined(separator: ","))]}"#.utf8)
    }

    static func write(_ cameras: [(id: Int64, lat: Double, lon: Double)], to url: URL) {
        try? data(cameras).write(to: url)
    }

    static func artifact(for data: Data) -> SpeedCameraArtifact {
        let sha = SpeedCameraFile.hex(SHA256.hash(data: data))
        return SpeedCameraArtifact(path: "/v1/cameras/\(sha).json", bytes: Int64(data.count),
                                   sha256: sha, count: nil, osmDataDate: "2026-10-28")
    }
}

final class SpeedCameraFileTests: XCTestCase {

    private let base = URL(string: "https://tiles.test")!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        StubURLProtocol.recorder.reset()
        dir = TestDirectories.fresh()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func serve(_ data: Data) {
        StubURLProtocol.recorder.reset { request in
            request.url.path.hasPrefix("/v1/cameras/") ? (200, data) : (404, Data())
        }
    }

    func testManifestListsTheSpeedCameraFile() throws {
        let json = Data("""
        {"schema":1,"build_id":"r1","valhalla_version":"3.6.3","packs":[],
         "speed_cameras":{"path":"/v1/cameras/abc.json","bytes":10,"sha256":"abc","count":2,"osm_data_date":"2026-10-28","license":"ODbL-1.0","build_id":"c1"}}
        """.utf8)

        let manifest = try JSONDecoder().decode(TileManifest.self, from: json)

        XCTAssertEqual(manifest.speedCameras?.path, "/v1/cameras/abc.json")
        XCTAssertEqual(manifest.speedCameras?.count, 2)
    }

    func testManifestFromAnOlderServerStillDecodes() throws {
        let json = Data(#"{"schema":1,"build_id":"r1","valhalla_version":"3.6.3","packs":[]}"#.utf8)

        XCTAssertNil(try JSONDecoder().decode(TileManifest.self, from: json).speedCameras)
    }

    func testDownloadVerifiesAndInstallsTheFile() async throws {
        let data = SpeedCameraFixture.data([(1, 40.5, -75.5)])
        serve(data)
        let dest = dir.appendingPathComponent("speed-cameras.json")
        let service = TilePackService(session: StubURLProtocol.session())

        let changed = try await service.downloadSpeedCameras(SpeedCameraFixture.artifact(for: data), base: base, to: dest)

        XCTAssertTrue(changed)
        XCTAssertEqual(try Data(contentsOf: dest), data)
        XCTAssertEqual(StubURLProtocol.recorder.all.map(\.url.host), ["tiles.test"])
    }

    func testAFileAlreadyOnDiskIsNotDownloadedAgain() async throws {
        let data = SpeedCameraFixture.data([(1, 40.5, -75.5)])
        serve(data)
        let dest = dir.appendingPathComponent("speed-cameras.json")
        try data.write(to: dest)

        let changed = try await TilePackService(session: StubURLProtocol.session())
            .downloadSpeedCameras(SpeedCameraFixture.artifact(for: data), base: base, to: dest)

        XCTAssertFalse(changed)
        XCTAssertEqual(StubURLProtocol.recorder.all.count, 0)
    }

    func testCorruptDownloadIsRejectedAndTheOldFileKept() async throws {
        let old = SpeedCameraFixture.data([(1, 40.5, -75.5)])
        let expected = SpeedCameraFixture.data([(2, 40.6, -75.5)])
        serve(SpeedCameraFixture.data([(3, 40.7, -75.5)]))
        let dest = dir.appendingPathComponent("speed-cameras.json")
        try old.write(to: dest)

        do {
            _ = try await TilePackService(session: StubURLProtocol.session())
                .downloadSpeedCameras(SpeedCameraFixture.artifact(for: expected), base: base, to: dest)
            XCTFail("expected a checksum failure")
        } catch TilePackError.checksumMismatch {}

        XCTAssertEqual(try Data(contentsOf: dest), old)
    }

    func testFileEntriesAreSpeedCamerasAndKeepRelationIDs() throws {
        let data = Data(#"{"cameras":[{"id":-9,"lat":40.5,"lon":-75.5,"tags":{"type":"enforcement","enforcement":"maxspeed"}}]}"#.utf8)

        let cameras = try XCTUnwrap(SpeedCameraFile.decode(data)).cameras

        XCTAssertEqual(cameras.map(\.osmID), [-9])
        XCTAssertEqual(cameras.map(\.surveillanceType), [.speedCamera])
    }
}
