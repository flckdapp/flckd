import CoreLocation
import Foundation
import MapKit

/// A delivery-jitter presentation buffer. Intervals use a monotonic wall clock,
/// not GPS timestamps (which may be warped by a development provider).
struct NavigationMotion {
    struct Pose {
        var coordinate: CLLocationCoordinate2D
        var heading: Double
    }

    private(set) var interval: TimeInterval = 1
    private var previousArrival: TimeInterval?
    private var start: Pose?
    private var target: Pose?
    private var startedAt: TimeInterval = 0
    private var path: [CLLocationCoordinate2D] = []
    private var lengths: [Double] = []
    private var onRoute = true
    private var duration: TimeInterval = 2
    private var initialRate = 1.0
    private var endingRate = 1.0
    private var pathLength = 0.0

    mutating func receive(_ pose: Pose, at now: TimeInterval,
                          route: [CLLocationCoordinate2D], onRoute: Bool) {
        let presented = sample(at: now) ?? pose
        let priorVelocity = velocity(at: now)
        if let previousArrival {
            let observed = now - previousArrival
            // Ignore duplicate deliveries, and restart cleanly after stale GPS.
            if observed <= 0.04 { return }
            let measured = min(5, max(0.1, observed))
            if abs(measured - interval) > interval * 0.6 {
                interval = measured
            } else {
                interval += (measured - interval) * 0.2
            }
        }
        let stale = previousArrival.map { now - $0 > 10 } ?? true
        previousArrival = now
        let changedMode = self.onRoute != onRoute
        self.onRoute = onRoute
        start = stale || changedMode ? pose : presented
        target = pose
        startedAt = now
        let origin = stale || changedMode ? pose : presented
        path = onRoute ? Self.path(from: origin.coordinate, to: pose.coordinate, route: route) : [origin.coordinate, pose.coordinate]
        let traveled = zip(path, path.dropFirst()).reduce(0.0) { $0 + Self.distance($1.0, $1.1) }
        // A reroute can replace geometry while the presentation buffer still
        // contains the old route. Do not animate a long trip round a loop.
        if traveled > max(250, Self.distance(origin.coordinate, pose.coordinate) * 5) {
            start = pose
            path = [pose.coordinate]
        }
        lengths = [0]
        for (a, b) in zip(path, path.dropFirst()) { lengths.append((lengths.last ?? 0) + Self.distance(a, b)) }
        pathLength = lengths.last ?? 0
        // A delivery-jitter reserve avoids reaching the fix and stopping
        // before the next callback. Match velocity at handoff with a monotone
        // Hermite segment instead of restarting an ease or changing slope.
        duration = interval * 2
        let average = pathLength / duration
        initialRate = average > 0 ? min(2, max(0, priorVelocity / average)) : 0
        endingRate = 1
    }

    func sample(at now: TimeInterval) -> Pose? {
        guard let start, let target else { return nil }
        let t = min(1, max(0, (now - startedAt) / duration))
        let fraction = progress(t)
        return Pose(coordinate: Self.point(on: path, lengths: lengths, fraction: fraction) ?? target.coordinate,
                    heading: Self.heading(from: start.heading, to: target.heading, fraction: fraction))
    }

    func isMoving(at now: TimeInterval) -> Bool { target != nil && now < startedAt + duration }

    private func progress(_ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return (t3 - 2 * t2 + t) * initialRate + (-2 * t3 + 3 * t2) + (t3 - t2) * endingRate
    }

    private func velocity(at now: TimeInterval) -> Double {
        guard now < startedAt + duration else { return 0 }
        let t = min(1, max(0, (now - startedAt) / duration))
        let derivative = (3 * t * t - 4 * t + 1) * initialRate + (-6 * t * t + 6 * t) + (3 * t * t - 2 * t) * endingRate
        return max(0, derivative * pathLength / duration)
    }

    static func heading(from: Double, to: Double, fraction: Double) -> Double {
        let delta = (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
        return (from + delta * min(1, max(0, fraction)) + 360).truncatingRemainder(dividingBy: 360)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Select the traversed polyline between projected fixes. Restrict the second
    /// projection to forward progress so a nearby returning road cannot win.
    static func path(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                     route: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard route.count > 1 else { return [from, to] }
        func project(_ coordinate: CLLocationCoordinate2D, minimum: Int) -> (index: Int, fraction: Double, error: Double) {
            let point = MKMapPoint(coordinate)
            var best = (index: minimum, fraction: 0.0, error: Double.infinity)
            for index in minimum..<(route.count - 1) {
                let a = MKMapPoint(route[index]), b = MKMapPoint(route[index + 1])
                let dx = b.x - a.x, dy = b.y - a.y
                let square = dx * dx + dy * dy
                let fraction = square > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / square)) : 0
                let error = hypot(point.x - a.x - fraction * dx, point.y - a.y - fraction * dy)
                if error < best.error { best = (index, fraction, error) }
            }
            return best
        }
        let a = project(from, minimum: 0), b = project(to, minimum: a.index)
        guard b.index >= a.index, b.index != a.index || b.fraction >= a.fraction else { return [from, to] }
        let vertices = b.index > a.index ? Array(route[(a.index + 1)...b.index]) : []
        return [from] + vertices + [to]
    }

    private static func point(on path: [CLLocationCoordinate2D], lengths: [Double], fraction: Double) -> CLLocationCoordinate2D? {
        guard let first = path.first, let total = lengths.last else { return nil }
        guard total > 0 else { return first }
        let position = total * fraction
        for index in 1..<path.count where lengths[index] >= position {
            let span = lengths[index] - lengths[index - 1]
            let t = span > 0 ? (position - lengths[index - 1]) / span : 1
            let a = MKMapPoint(path[index - 1]), b = MKMapPoint(path[index])
            return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t).coordinate
        }
        return path.last
    }
}

struct NavigationZoom {
    private(set) var distance = 450.0
    private var filteredSpeed = 0.0
    private var target = 450.0
    private var lastTime: TimeInterval?
    private(set) var isSettling = false

    /// City view stays readable; an accelerating quadratic opens the next
    /// junction at highway speeds without zooming excessively at every crawl.
    static func distance(for speed: Double) -> Double {
        let mph = (speed.isFinite ? max(0, speed) : 0) * 3600 / 1609.344
        let fraction = min(1, max(0, (mph - 20) / 50))
        return 450 + 1250 * fraction * fraction
    }

    mutating func update(speed: Double?, at now: TimeInterval) -> Double {
        let dt = min(2, max(0, lastTime.map { now - $0 } ?? 0))
        lastTime = now
        if let speed, speed.isFinite, speed >= 0 {
            filteredSpeed += (speed - filteredSpeed) * (1 - exp(-dt / 3))
            let proposed = Self.distance(for: filteredSpeed)
            if abs(proposed - target) >= 70 { target = proposed }
        }
        distance += (target - distance) * (1 - exp(-dt / 2.5))
        isSettling = abs(target - distance) > 0.1
        return distance
    }
}
