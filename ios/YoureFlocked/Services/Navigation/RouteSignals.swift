import CoreLocation
import Foundation
@preconcurrency import FerrostarCoreFFI

/// In-memory route enrichment only. Failure leaves ordinary distance prompts.
struct RouteSignals: Sendable {
    struct Signal: Sendable {
        let coordinate: GeographicCoordinate
        let distanceAlongRoute: Double
    }
    var signals: [Signal] = []

    static func load(geometry: [GeographicCoordinate], costing: String = "auto") async -> Self {
        do {
            guard geometry.count > 1, LocalValhallaEngine.shared.hasRegion else { return Self() }
            let request: [String: Any] = [
                "shape": geometry.map { ["lat": $0.lat, "lon": $0.lng] },
                "costing": costing, "shape_match": "edge_walk",
                "filters": ["action": "include", "attributes": ["shape", "edge.end_shape_index", "node.traffic_signal"]],
            ]
            let json = try JSONSerialization.data(withJSONObject: request)
            guard let raw = String(data: json, encoding: .utf8) else { return Self() }
            let data = try await LocalValhallaEngine.shared.traceAttributes(rawRequest: raw)
            return try parse(data)
        } catch {
            // Optional enrichment: do not log a trace, route, or native error
            // (which can contain route data), and never block guidance.
            return Self()
        }
    }

    static func parse(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Edge: Decodable {
                struct Node: Decodable { let traffic_signal: Bool? }
                let end_shape_index: Int
                let end_node: Node?
            }
            let shape: String
            let edges: [Edge]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let shape = try decodePolyline(response.shape)
        let distances = cumulative(shape)
        let indices = Set(response.edges.filter { $0.end_node?.traffic_signal == true }.map(\.end_shape_index))
        return Self(signals: indices.sorted().compactMap { index in
            guard shape.indices.contains(index) else { return nil }
            return Signal(coordinate: shape[index], distanceAlongRoute: distances[index])
        })
    }

    func prefix(maneuver: GeographicCoordinate, targetDistance: Double, userDistance: Double, approach: Bool) -> String? {
        guard let target = signals.min(by: {
            abs($0.distanceAlongRoute - targetDistance) < abs($1.distanceAlongRoute - targetDistance)
        }), abs(target.distanceAlongRoute - targetDistance) <= 40,
              Self.distance(target.coordinate, maneuver) <= 25 else { return nil }
        if !approach { return "at_light" }
        let intervening = signals.filter {
            $0.distanceAlongRoute > userDistance + 5 && $0.distanceAlongRoute < target.distanceAlongRoute - 25
        }
        switch intervening.count {
        case 0: return "at_next_light"
        case 1: return "at_second_light"
        default: return nil
        }
    }

    static func distance(_ a: GeographicCoordinate, _ b: GeographicCoordinate) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lng).distance(from: CLLocation(latitude: b.lat, longitude: b.lng))
    }

    static func cumulative(_ shape: [GeographicCoordinate]) -> [Double] {
        guard !shape.isEmpty else { return [] }
        var result = [0.0]
        for index in 1..<shape.count { result.append(result[index - 1] + distance(shape[index - 1], shape[index])) }
        return result
    }

    private static func decodePolyline(_ encoded: String) throws -> [GeographicCoordinate] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0
        var lon = 0
        var result: [GeographicCoordinate] = []
        func component() throws -> Int {
            var value = 0
            var shift = 0
            while index < bytes.count, shift < 35 {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard byte >= 0 else { throw RoutingError.invalidResponse }
                value |= (byte & 31) << shift
                if byte < 32 { return value & 1 == 1 ? ~(value >> 1) : value >> 1 }
                shift += 5
            }
            throw RoutingError.invalidResponse
        }
        while index < bytes.count {
            lat += try component()
            lon += try component()
            result.append(GeographicCoordinate(lat: Double(lat) / 1_000_000, lng: Double(lon) / 1_000_000))
        }
        return result
    }
}
