import Foundation

/// Intercepts every request on a test session, records it, and answers
/// from a handler. Nothing reaches the network.
final class StubURLProtocol: URLProtocol {

    struct RecordedRequest: Sendable {
        let url: URL
        let method: String
        let body: String

        var host: String { url.host ?? "" }
        var decodedBody: String { body.removingPercentEncoding ?? body }
    }

    typealias Handler = @Sendable (RecordedRequest) -> (status: Int, body: Data)

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [RecordedRequest] = []
        private var handler: Handler = StubURLProtocol.defaultHandler

        func reset(handler: Handler? = nil) {
            lock.lock(); defer { lock.unlock() }
            requests = []
            self.handler = handler ?? StubURLProtocol.defaultHandler
        }

        func record(_ request: RecordedRequest) -> (status: Int, body: Data) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return handler(request)
        }

        var all: [RecordedRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        var overpass: [RecordedRequest] { all.filter { $0.host.contains("overpass") } }
        var cdn: [RecordedRequest] { all.filter { $0.host.contains("deflock.me") } }
    }

    static let recorder = Recorder()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static let emptyOverpass = Data(#"{"version":0.6,"elements":[]}"#.utf8)

    /// An index with no published tiles: the CDN is up and has no ALPRs.
    static let emptyCDNIndex = Data("""
    {"expiration_utc": 4102444800,
     "tile_url": "https://cdn.deflock.me/regions/{lat}/{lon}.json?v=1",
     "tile_size_degrees": 20,
     "regions": []}
    """.utf8)

    static let defaultHandler: Handler = { request in
        if request.host.contains("overpass") { return (200, emptyOverpass) }
        if request.url.path.hasSuffix("index.json") { return (200, emptyCDNIndex) }
        return (404, Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let recorded = RecordedRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            body: Self.readBody(request)
        )
        let (status, body) = Self.recorder.record(recorded)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a POST body to a protocol as a stream, not as
    /// `httpBody`.
    private static func readBody(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum TestDirectories {
    static func fresh() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flckd-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
