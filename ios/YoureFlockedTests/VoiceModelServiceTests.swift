import CryptoKit
import XCTest
@testable import YoureFlocked

final class VoiceModelServiceTests: XCTestCase {
    private var root: URL!
    private let base = URL(string: "https://tiles.example/sub")!

    override func setUp() {
        root = TestDirectories.fresh()
        StubURLProtocol.recorder.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        StubURLProtocol.recorder.reset()
    }

    private static func sha(_ data: Data) -> String { SpeedCameraFile.hex(SHA256.hash(data: data)) }

    /// A minimal ustar writer, enough for the reader under test.
    static func tar(_ members: [(String, Data)]) -> Data {
        var out = Data()
        for (name, body) in members {
            var header = Data(count: 512)
            func put(_ string: String, _ at: Int) { header.replaceSubrange(at..<at + string.utf8.count, with: Data(string.utf8)) }
            put(name, 0)
            put("0000644\0", 100)
            put("0000000\0", 108)
            put("0000000\0", 116)
            put(String(format: "%011o\0", body.count), 124)
            put("00000000000\0", 136)
            put("        ", 148)
            header[156] = UInt8(ascii: "0")
            put("ustar\0", 257)
            put("00", 263)
            let sum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o\0 ", sum), 148)
            out.append(header)
            out.append(body)
            out.append(Data(count: (512 - body.count % 512) % 512))
        }
        out.append(Data(count: 1024))
        return out
    }

    private struct Fixture {
        let descriptor: KokoroPackDescriptor
        let objects: [String: Data]
    }

    private func fixture(corrupt: Bool = false) -> Fixture {
        let archive = Self.tar([("turn_left.m4a", Data("left".utf8)), ("turn_right.m4a", Data("right".utf8))])
        let model = Data(repeating: 7, count: 300)
        let clipsPath = "v1/voice/kokoro/blobs/\(Self.sha(archive))"
        let modelPath = "v1/voice/kokoro/blobs/\(Self.sha(model))"
        let preset = KokoroPackDescriptor.Preset(
            id: "heart", name: "Heart", upstream: "af_heart", sid: 3, gainDB: 0,
            clips: .init(path: clipsPath, bytes: Int64(archive.count), sha256: Self.sha(archive), count: 2))
        let files = KokoroVoiceStore.modelFileNames.map { name in
            KokoroPackDescriptor.ModelFile(name: name, bytes: Int64(model.count), sha256: Self.sha(model),
                                           parts: [.init(path: modelPath, bytes: Int64(model.count), sha256: Self.sha(model))])
        }
        let descriptor = KokoroPackDescriptor(schema: 1, id: "kokoro-test", engine: "test", presets: [preset],
                                              model: .init(files: files))
        var archiveServed = archive
        if corrupt { archiveServed[archiveServed.startIndex] ^= 0xFF }
        return Fixture(descriptor: descriptor, objects: ["/sub/" + clipsPath: archiveServed, "/sub/" + modelPath: model])
    }

    private func service(_ fixture: Fixture, status: Int = 200) -> (VoiceModelService, KokoroVoiceStore) {
        let objects = fixture.objects
        StubURLProtocol.recorder.reset { request in
            guard status == 200 else { return (status, Data()) }
            return objects[request.url.path].map { (200, $0) } ?? (404, Data())
        }
        let store = KokoroVoiceStore(root: root, descriptor: fixture.descriptor)
        return (VoiceModelService(session: StubURLProtocol.session(), store: store, base: base), store)
    }

    func testGoodDownloadsInstallClipsAndModel() async throws {
        let (service, store) = service(fixture())
        let heart = KokoroPreset(store.descriptor.presets[0])
        try await service.downloadClips { _ in }
        XCTAssertTrue(store.clipsInstalled(preset: heart))
        let clip = try XCTUnwrap(store.clipURL(preset: heart, key: "turn_right"))
        XCTAssertEqual(try Data(contentsOf: clip), Data("right".utf8))
        try await service.downloadModel { _ in }
        XCTAssertTrue(store.modelInstalled())
        XCTAssertNotNil(store.modelPaths())
    }

    func testRequestsGoToTheConfiguredBase() async throws {
        let (service, _) = service(fixture())
        try await service.downloadClips { _ in }
        let urls = StubURLProtocol.recorder.all.map(\.url.absoluteString)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].hasPrefix("https://tiles.example/sub/v1/voice/kokoro/blobs/"), urls[0])
    }

    func testWrongHashInstallsNothing() async throws {
        let (service, store) = service(fixture(corrupt: true))
        do {
            try await service.downloadClips { _ in }
            XCTFail("expected a checksum error")
        } catch let error as TilePackError {
            guard case .checksumMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(store.clipsInstalled(preset: KokoroPreset(store.descriptor.presets[0])))
        XCTAssertNil(try? FileManager.default.contentsOfDirectory(atPath: store.clipsDirectory(preset: "heart").path))
    }

    func testMissingPackIsReportedAsNotOffered() async throws {
        let (service, _) = service(fixture(), status: 404)
        do {
            try await service.downloadModel { _ in }
            XCTFail("expected notOffered")
        } catch {
            XCTAssertEqual(error as? VoiceModelError, .notOffered)
            XCTAssertEqual(error.localizedDescription, "This tile server doesn't offer the Kokoro voice.")
        }
    }

    func testTarReaderExtractsAndRejectsPathsOutsideItsDirectory() throws {
        let two = try TarReader.entries(Self.tar([("a.m4a", Data("A".utf8)), ("b.m4a", Data(repeating: 1, count: 600))]))
        XCTAssertEqual(two.map(\.name), ["a.m4a", "b.m4a"])
        XCTAssertEqual(two[1].data.count, 600)
        XCTAssertThrowsError(try TarReader.entries(Self.tar([("../x", Data("x".utf8))]))) { error in
            XCTAssertEqual(error as? TarReader.Error, .unsupportedMember("../x"))
        }
    }
}
