import XCTest
import CoreLocation
@testable import YoureFlocked

/// What actually goes over the wire to Overpass.
final class OverpassRequestTests: XCTestCase {

    private let cell = GridCell(lat: 40, lon: -76)
    private var cacheDir: URL!

    override func setUp() {
        super.setUp()
        StubURLProtocol.recorder.reset()
        cacheDir = TestDirectories.fresh()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    private func makeService() -> OverpassService {
        OverpassService(session: StubURLProtocol.session(), cacheDirectory: cacheDir)
    }

    func testQueryIsPostedWithIntegerBoxAndNothingInTheURL() async throws {
        _ = try await makeService().speedCameras(in: cell)

        let requests = StubURLProtocol.recorder.overpass
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertNil(request.url.query, "the box must not be in the URL")
        XCTAssertTrue(request.decodedBody.hasPrefix("data="))
        XCTAssertTrue(request.decodedBody.contains("(40,-76,41,-75)"))
        XCTAssertNil(request.decodedBody.range(of: #"\d\.\d"#, options: .regularExpression),
                     "body must not contain a fractional number: \(request.decodedBody)")
    }

    func testFreshCellIsServedFromDiskWithoutARequest() async throws {
        _ = try await makeService().speedCameras(in: cell)
        _ = try await makeService().speedCameras(in: cell)

        XCTAssertEqual(StubURLProtocol.recorder.overpass.count, 1)
    }

    func testFailureReachesAtMostTwoHosts() async {
        StubURLProtocol.recorder.reset { _ in (500, Data()) }

        do {
            _ = try await makeService().speedCameras(in: cell)
            XCTFail("expected the fetch to fail")
        } catch {}

        let hosts = Set(StubURLProtocol.recorder.overpass.map(\.host))
        XCTAssertLessThanOrEqual(hosts.count, OverpassService.maxEndpointsPerFetch)
        XCTAssertEqual(StubURLProtocol.recorder.overpass.count, 3)
    }

    func testStaleCellIsServedWhenTheNetworkFails() async throws {
        _ = try await makeService().speedCameras(in: cell)
        StubURLProtocol.recorder.reset { _ in (500, Data()) }

        let cameras = try await makeService().speedCameras(in: cell)

        XCTAssertEqual(cameras, [])
        XCTAssertEqual(StubURLProtocol.recorder.overpass.count, 0, "fresh cache must not be re-requested")
    }
}
