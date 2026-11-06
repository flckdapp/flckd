import CoreLocation
import Foundation

/// Builds the shape of a Valhalla `format: osrm` answer, trimmed to the fields
/// Ferrostar's parser requires: `intersections` and `components` have no serde
/// default, so they must be present even when empty.
///
/// Every coordinate a caller passes in is synthetic: offsets from the null
/// island, never a place.
enum OSRMFixture {

    struct Step {
        var geometry: [CLLocationCoordinate2D]
        var maneuverType: String
        var modifier: String?
        var instruction: String
        var roadName: String = "Test Street"
        var distanceMeters: Double
        var durationSeconds: Double = 15
    }

    enum Error: Swift.Error {
        case emptyRoute
    }

    static func response(steps: [Step]) throws -> Data {
        guard let start = steps.first?.geometry.first, let end = steps.last?.geometry.last else {
            throw Error.emptyRoute
        }
        let distance = steps.map(\.distanceMeters).reduce(0, +)
        let duration = steps.map(\.durationSeconds).reduce(0, +)
        let payload: [String: Any] = [
            "code": "Ok",
            "waypoints": [
                ["location": [start.longitude, start.latitude], "name": "Start"],
                ["location": [end.longitude, end.latitude], "name": "Finish"],
            ],
            "routes": [[
                "distance": distance,
                "duration": duration,
                "geometry": PolylineEncoder.encode(routeShape(of: steps)),
                "legs": [[
                    "distance": distance,
                    "duration": duration,
                    "steps": steps.map(json),
                ]],
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// One 111.3 m step per segment of `shape`: a departure, then turns.
    static func response(shape: [CLLocationCoordinate2D]) throws -> Data {
        let steps = (0 ..< shape.count - 1).map { index in
            Step(
                geometry: [shape[index], shape[index + 1]],
                maneuverType: index == 0 ? "depart" : "turn",
                modifier: index == 0 ? nil : "right",
                instruction: index == 0 ? "Head north" : "Turn right",
                distanceMeters: 111.3
            )
        }
        return try response(steps: steps)
    }

    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Consecutive steps share their joining vertex; the route-level shape
    /// carries it once, as Valhalla's does.
    private static func routeShape(of steps: [Step]) -> [CLLocationCoordinate2D] {
        var shape: [CLLocationCoordinate2D] = []
        for point in steps.flatMap(\.geometry) {
            if let last = shape.last, last.latitude == point.latitude, last.longitude == point.longitude {
                continue
            }
            shape.append(point)
        }
        return shape
    }

    private static func json(_ step: Step) -> [String: Any] {
        let from = step.geometry[0]
        var maneuver: [String: Any] = [
            "location": [from.longitude, from.latitude],
            "bearing_before": 0,
            "bearing_after": 90,
            "type": step.maneuverType,
            "instruction": step.instruction,
        ]
        var primary: [String: Any] = [
            "text": step.instruction,
            "type": step.maneuverType,
            "components": [],
        ]
        if let modifier = step.modifier {
            maneuver["modifier"] = modifier
            primary["modifier"] = modifier
        }
        return [
            "distance": step.distanceMeters,
            "duration": step.durationSeconds,
            "geometry": PolylineEncoder.encode(step.geometry),
            "name": step.roadName,
            "mode": "drive",
            "maneuver": maneuver,
            "intersections": [[
                "location": [from.longitude, from.latitude],
                "bearings": [90],
                "entry": [true],
            ]],
            "bannerInstructions": [[
                "distanceAlongGeometry": step.distanceMeters,
                "primary": primary,
            ]],
            "voiceInstructions": [[
                "distanceAlongGeometry": step.distanceMeters,
                "announcement": step.instruction,
            ]],
        ]
    }
}
