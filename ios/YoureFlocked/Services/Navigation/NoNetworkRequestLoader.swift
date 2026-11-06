import FerrostarCore
import Foundation

enum NavigationError: LocalizedError, Equatable {
    case networkDisabled
    case noWaypoints
    case noRouteInResponse

    var errorDescription: String? {
        switch self {
        case .networkDisabled:
            return "Turn-by-turn guidance never uses the network."
        case .noWaypoints:
            return "A guidance route needs a destination."
        case .noRouteInResponse:
            return "The routing engine returned no usable route."
        }
    }
}

/// The `URLRequestLoading` handed to `FerrostarCore`.
///
/// FerrostarCore only reaches its network session on the `.routeAdapter`
/// path, and this app always uses a `CustomRouteProvider` over the on-device
/// engine, so the session is unreachable by construction. Injecting a loader
/// that throws turns that from a property of the call graph into one anybody
/// can read off a single file: if guidance ever acquires a network path, it
/// fails loudly instead of quietly making PRIVACY.md false.
struct NoNetworkRequestLoader: URLRequestLoading {
    func loadData(with _: URLRequest) async throws -> (Data, URLResponse) {
        throw NavigationError.networkDisabled
    }
}
