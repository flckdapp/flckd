import CoreLocation
import Foundation

/// Shared point-to-segment geometry for planner scoring and speech filtering.
enum CameraExposureGeometry {
    static let radiusMeters = 35.0

    struct Projection {
        let coordinate: CLLocationCoordinate2D
        let distance: Double
        let fraction: Double
    }

    static func project(_ point: CLLocationCoordinate2D, onto a: CLLocationCoordinate2D,
                        _ b: CLLocationCoordinate2D, referenceLatitude: Double) -> Projection {
        let latitudeScale = 111_320.0
        let longitudeScale = latitudeScale * max(0.01, cos(referenceLatitude * .pi / 180))
        let dx = (b.longitude - a.longitude) * longitudeScale
        let dy = (b.latitude - a.latitude) * latitudeScale
        let px = (point.longitude - a.longitude) * longitudeScale
        let py = (point.latitude - a.latitude) * latitudeScale
        let square = dx * dx + dy * dy
        let fraction = square > 0 ? min(1, max(0, (px * dx + py * dy) / square)) : 0
        return Projection(coordinate: CLLocationCoordinate2D(latitude: a.latitude + fraction * (b.latitude - a.latitude),
                                                           longitude: a.longitude + fraction * (b.longitude - a.longitude)),
                          distance: hypot(px - fraction * dx, py - fraction * dy), fraction: fraction)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// Conservative visibility estimate, not a claim about optics or elevation.
/// Both a planned route and a recent raw track use this same predicate.
enum CameraObservability {
    static let undirectedRadius = 25.0
    static let undirectedMinimumOffset = 5.0
    static let undirectedStretch = 30.0
    static let directedStretch = 10.0

    static func canObserve(camera: SurveillanceCamera, position: CLLocationCoordinate2D, course: Double) -> Bool {
        guard course.isFinite, course >= 0 else { return false }
        let rawDirection = camera.tags["direction"] ?? camera.tags["camera:direction"]
        if let rawDirection, !rawDirection.isEmpty, camera.directions.isEmpty { return false }
        let directed = !camera.directions.isEmpty
        let radius = directed ? CameraExposureGeometry.radiusMeters : undirectedRadius
        guard CameraExposureGeometry.distance(camera.coordinate, position) <= radius,
              camera.isInFieldOfView(from: position) else { return false }
        // Without a watched-road axis, a centerline crossing is ambiguous
        // (including grade-separated roads). Only a shoulder-like offset is
        // accepted; this deliberately misses undirected overhead cameras.
        guard directed else {
            return CameraExposureGeometry.distance(camera.coordinate, position) >= undirectedMinimumOffset
        }
        // A camera's look direction defines its watched road axis. Either
        // travel direction can be seen, but a perpendicular crossing cannot.
        return camera.directions.contains { entry in
            let delta = abs((course - entry.center + 540).truncatingRemainder(dividingBy: 360) - 180)
            let bearing = SurveillanceCamera.bearing(from: camera.coordinate, to: position)
            let viewAngle = abs((bearing - entry.center + 540).truncatingRemainder(dividingBy: 360) - 180)
            return viewAngle <= entry.halfAngle
                && min(delta, 180 - delta) <= min(entry.halfAngle, SurveillanceCamera.defaultHalfAngle)
        }
    }

    struct Window: Equatable, Sendable {
        let start: Double
        let end: Double
    }

    /// Only inspect the portion of each segment near the camera. 2.5-metre
    /// samples make long sparse route edges and densely sampled tracks agree.
    static func windows(camera: SurveillanceCamera, path: [CLLocationCoordinate2D]) -> [Window] {
        guard path.count > 1 else { return [] }
        let radius = camera.directions.isEmpty ? undirectedRadius : CameraExposureGeometry.radiusMeters
        let minimum = camera.directions.isEmpty ? undirectedStretch : directedStretch
        var offset = 0.0
        var runs: [Window] = []
        var runStart: Double?
        var runEnd = 0.0
        func finish() {
            if let start = runStart, runEnd - start >= minimum - 2.5 { runs.append(Window(start: start, end: runEnd)) }
            runStart = nil
        }
        for (a, b) in zip(path, path.dropFirst()) {
            let length = CameraExposureGeometry.distance(a, b)
            defer { offset += length }
            guard length > 0 else { continue }
            let latitudeMargin = radius / 110_000
            let longitudeMargin = latitudeMargin / max(0.01, cos(camera.latitude * .pi / 180))
            guard camera.latitude >= min(a.latitude, b.latitude) - latitudeMargin,
                  camera.latitude <= max(a.latitude, b.latitude) + latitudeMargin,
                  camera.longitude >= min(a.longitude, b.longitude) - longitudeMargin,
                  camera.longitude <= max(a.longitude, b.longitude) + longitudeMargin else { finish(); continue }
            let projection = CameraExposureGeometry.project(camera.coordinate, onto: a, b, referenceLatitude: camera.latitude)
            guard projection.distance <= radius else { finish(); continue }
            let center = projection.fraction * length
            let lower = max(0, center - radius)
            let upper = min(length, center + radius)
            let count = max(1, Int(ceil((upper - lower) / 2.5)))
            let course = SurveillanceCamera.bearing(from: a, to: b)
            for sample in 0...count {
                let distance = lower + (upper - lower) * Double(sample) / Double(count)
                let fraction = distance / length
                let point = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                                  longitude: a.longitude + (b.longitude - a.longitude) * fraction)
                let along = offset + distance
                if canObserve(camera: camera, position: point, course: course) {
                    if runStart != nil, along - runEnd > 5 { finish() }
                    if runStart == nil { runStart = along }
                    runEnd = along
                } else { finish() }
            }
            if upper < length { finish() }
        }
        finish()
        return runs
    }

    struct RouteExposure: Sendable {
        var windowsByCamera: [Int64: [Window]] = [:]
        var orderedIDs: [Int64] { windowsByCamera.keys.sorted {
            let a = windowsByCamera[$0]?.first?.start ?? 0, b = windowsByCamera[$1]?.first?.start ?? 0
            return a == b ? $0 < $1 : a < b
        } }
        var exposedIDs: Set<Int64> { Set(windowsByCamera.keys) }

        func passedIDs(from previous: Double, to progress: Double) -> Set<Int64> {
            Set(windowsByCamera.compactMap { id, windows in
                windows.contains { $0.start <= progress && $0.end >= previous } ? id : nil
            })
        }

        static func build(path: [CLLocationCoordinate2D], cameras: [SurveillanceCamera],
                          filter: CameraTypeFilter = .all) -> Self {
            var result = Self()
            for camera in cameras where filter.allows(camera) {
                if Task.isCancelled { return Self() }
                let windows = CameraObservability.windows(camera: camera, path: path)
                if !windows.isEmpty { result.windowsByCamera[camera.id] = windows }
            }
            return result
        }

        func permits(camera: SurveillanceCamera, progress: Double, alertRadius: Double, passing: Bool,
                     position: CLLocationCoordinate2D, course: Double) -> Bool {
            guard let windows = windowsByCamera[camera.id], progress.isFinite else { return false }
            if passing {
                return windows.contains { progress >= $0.start && progress <= $0.end }
                    && CameraObservability.canObserve(camera: camera, position: position, course: course)
            }
            return windows.contains { progress <= $0.end && $0.start - progress <= alertRadius }
        }
    }
}

struct CameraSpeechTrack {
    private(set) var fixes: [CLLocation] = []

    mutating func append(_ location: CLLocation) {
        fixes.removeAll { location.timestamp.timeIntervalSince($0.timestamp) > 15 }
        if let last = fixes.last {
            let dt = location.timestamp.timeIntervalSince(last.timestamp)
            if dt <= 0 || last.distance(from: location) > 500 { fixes.removeAll() }
        }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 35 else { fixes.removeAll(); return }
        fixes.append(location)
        if fixes.count > 16 { fixes.removeFirst(fixes.count - 16) }
    }

    func permits(_ camera: SurveillanceCamera, at location: CLLocation) -> Bool {
        guard let first = fixes.first, let last = fixes.last, fixes.count >= 2,
              first.distance(from: last) >= 10,
              CameraObservability.canObserve(camera: camera, position: location.coordinate, course: location.course) else { return false }
        let trackCourse = SurveillanceCamera.bearing(from: first.coordinate, to: last.coordinate)
        let delta = abs((trackCourse - location.course + 540).truncatingRemainder(dividingBy: 360) - 180)
        guard delta <= SurveillanceCamera.defaultHalfAngle else { return false }
        return !CameraObservability.windows(camera: camera, path: fixes.map(\.coordinate)).isEmpty
    }
}

/// Rechecked by the serial player after waiting behind guidance. A group must
/// still describe every camera it counted, not a stale or now-filtered set.
struct CameraSpeechEligibility: Sendable {
    var entry = Set<Int64>()
    var passing = Set<Int64>()

    func allows(_ utterance: VoiceUtterance) -> Bool {
        guard !utterance.cameraTargets.isEmpty else { return true }
        let allowed = utterance.cameraRequiresView ? passing : entry
        return utterance.cameraTargets.isSubset(of: allowed)
    }
}
