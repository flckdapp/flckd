import Foundation
import UIKit
import Valhalla
import ValhallaConfigModels

/// Owns the one long-lived `Valhalla` engine. All native calls run on `queue`,
/// a dedicated serial queue rather than the Swift concurrency cooperative pool,
/// because `Valhalla.route(rawRequest:)` is synchronous and blocking.
final class LocalValhallaEngine: @unchecked Sendable {

    static let shared = LocalValhallaEngine()

    private let queue = DispatchQueue(label: "app.flckd.valhalla", qos: .userInitiated)
    private var engine: Valhalla?          // touched only on `queue`
    private var loadedRegion: URL?         // touched only on `queue`

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.shutdown() }
        center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.shutdown() }
    }

    /// True when a usable region extract is on disk. Cheap; does not build the engine.
    var hasRegion: Bool { RegionStore.bestAvailableRegion() != nil }

    /// Runs a raw Valhalla `route` request on-device.
    /// - Returns: raw `{"trip": ...}` JSON, identical in shape to the HTTP API.
    func route(rawRequest json: String, region: URL? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let engine = try self.engineOnQueue(preferred: region)
                    let response = try engine.route(rawRequest: json)   // blocking, sync
                    guard let data = response.data(using: .utf8) else {
                        throw RoutingError.invalidResponse
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: Self.map(error))
                }
            }
        }
    }

    /// Builds the engine lazily and reuses it. Construction is expensive
    /// (mmap + index parse + tzdata extraction).
    private func engineOnQueue(preferred: URL? = nil) throws -> Valhalla {
        dispatchPrecondition(condition: .onQueue(queue))
        let best = preferred ?? RegionStore.bestAvailableRegion()
        if let engine, loadedRegion == best { return engine }

        self.engine?.close()
        self.engine = nil
        self.loadedRegion = nil

        guard let tarURL = best else {
            throw RoutingError.engineUnavailable
        }
        // ValhallaConfig uses URL.relativePath internally, so the URL has to
        // be an absolute file URL.
        let absolute = URL(fileURLWithPath: tarURL.path)

        var config = try ValhallaConfig(tileExtractTar: absolute)
        // The shipped default.json sets max_cache_size to 1 GB (a server
        // setting); it costs ~15.6 MB of dirty RSS at construction. 32 MB is
        // plenty on-device.
        config.mjolnir?.maxCacheSize = 32_000_000
        // The default service limits cap the total perimeter of all
        // exclude_polygons at about 10 km, roughly 50 camera circles at 30 m
        // radius. Aggressive avoidance excludes hundreds of cameras at up to
        // 100 m radius, so raise the cap well above any realistic corridor.
        config.serviceLimits?.maxExcludePolygonsLength = 1_000_000

        let built = try Valhalla(config, configName: "flckd-valhalla.json")
        self.engine = built
        self.loadedRegion = tarURL
        return built
    }

    /// Releases the native engine and unmaps the extract. Idempotent.
    /// Call before deleting or replacing a region file.
    func shutdown() {
        queue.async {
            self.engine?.close()
            self.engine = nil
            self.loadedRegion = nil
        }
    }

    /// Translates the package's errors into the app's own vocabulary.
    private static func map(_ error: Error) -> Error {
        if let routing = error as? RoutingError { return routing }
        guard let error = error as? ValhallaError else { return error }
        switch error {
        case .valhallaError(let code, let message):
            // 442 = no path between locations; 171 = no suitable edges near
            // location. Both mean the exclude set is too aggressive, so report
            // noRouteFound and let routeWithProgressiveAvoidance retry.
            if code == 442 || code == 171 || message.contains("No path could be found") {
                return RoutingError.noRouteFound
            }
            return RoutingError.badRequest(message)
        case .closed:
            return RoutingError.engineUnavailable
        case .tzdataUnavailable(let reason):
            return RoutingError.badRequest("timezone data: \(reason)")
        case .notSupported(let format):
            return RoutingError.badRequest("unsupported format: \(format)")
        case .encodingNotUtf8:
            return RoutingError.invalidResponse
        }
    }
}
