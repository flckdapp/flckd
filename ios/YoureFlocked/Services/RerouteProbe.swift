#if DEBUG
import Foundation
import CoreLocation

/// Drives repeated route planning so reroute latency can be measured without
/// anyone touching the phone.
///
/// Two modes answer two different questions:
///
/// - `drive` replans from the live GPS position to a fixed destination on a
///   timer. It measures what a real reroute costs at speed, including thermal
///   throttling and engine teardown after backgrounding. The computed route is
///   discarded; nothing the driver sees changes.
/// - `sweep` plans between pairs of cached camera positions while stationary.
///   Cameras sit beside roads, so they make cheap anchors that land in exactly
///   the dense areas where planning is most expensive. This covers the
///   geography axis without driving anywhere.
@MainActor
@Observable
final class RerouteProbe {

    /// Shared so a run outlives the view that started it. The overlay lives in
    /// a `safeAreaInset` on one tab, and a view-owned probe would be torn down
    /// by a tab switch mid-drive, silently ending the measurement.
    static let shared = RerouteProbe()

    enum Mode: String, Sendable {
        case drive
        case sweep
    }

    private(set) var isRunning = false
    private(set) var mode: Mode = .drive
    private(set) var completed = 0
    private(set) var plannedTotal = 0
    private(set) var lastError: String?

    var intervalSeconds: Double = 20
    var sweepCount: Int = 25

    /// Fixed so two devices sweep the same pairs. Comparing an A14 against an
    /// A18 only means something if both planned identical work.
    var sweepSeed: UInt64 = 0x464C434B44

    /// Straight-line separation for synthetic sweep pairs. Short enough to
    /// plan quickly, long enough to look like a real trip.
    private let sweepRangeMeters: ClosedRange<Double> = 3_000...15_000

    private var task: Task<Void, Never>?
    private let service = ValhallaRoutingService()

    // MARK: - Drive

    func startDrive(
        to destination: CLLocationCoordinate2D,
        level: AvoidanceLevel,
        cameraStore: CameraStore,
        locationManager: LocationManager
    ) {
        stop()
        mode = .drive
        completed = 0
        plannedTotal = 0
        lastError = nil
        isRunning = true

        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let fix = locationManager.currentLocation {
                    await self.plan(
                        from: fix.coordinate,
                        to: destination,
                        level: level,
                        cameras: cameraStore.cameras,
                        trigger: .auto,
                        speedMps: fix.speed >= 0 ? fix.speed : nil
                    )
                } else {
                    self.lastError = "Waiting for a location fix"
                }
                try? await Task.sleep(for: .seconds(self.intervalSeconds))
            }
        }
    }

    // MARK: - Sweep

    func startSweep(level: AvoidanceLevel, cameraStore: CameraStore) {
        stop()
        mode = .sweep
        completed = 0
        lastError = nil
        isRunning = true

        // Sorted by OSM id so the anchor list is in the same order on every
        // device regardless of the order cameras arrived in.
        let anchors = cameraStore.cameras.sorted { $0.id < $1.id }
        plannedTotal = sweepCount

        guard anchors.count >= 2 else {
            lastError = "Need cached cameras to sweep. Open the map first."
            isRunning = false
            return
        }

        RoutingMetricsStore.shared.sweepContext = SweepContext(
            seed: sweepSeed,
            anchorCount: anchors.count,
            anchorFingerprint: Self.fingerprint(anchors.map(\.id))
        )

        var generator = SeededGenerator(seed: sweepSeed)

        task = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<self.sweepCount {
                if Task.isCancelled { break }
                guard let pair = Self.pair(from: anchors, separation: self.sweepRangeMeters, using: &generator) else {
                    self.lastError = "No camera pair within the sweep range"
                    break
                }
                await self.plan(
                    from: pair.start,
                    to: pair.end,
                    level: level,
                    cameras: anchors,
                    trigger: .sweep,
                    speedMps: nil
                )
            }
            self.isRunning = false
        }
    }

    /// Rejection-samples a pair separated by a plausible trip distance.
    /// Gives up rather than looping forever when the cached set is clustered
    /// too tightly to produce one.
    private static func pair(
        from cameras: [SurveillanceCamera],
        separation: ClosedRange<Double>,
        using generator: inout SeededGenerator
    ) -> (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)? {
        // Indexing by hand rather than through `Int.random(in:using:)`. The
        // stdlib ships with the OS, so two phones on different point releases
        // could in principle derive different indices from the same generator
        // state, which would silently invalidate the cross-device comparison.
        // Modulo bias does not matter here; reproducibility does.
        let count = UInt64(cameras.count)
        for _ in 0..<200 {
            let a = cameras[Int(generator.next() % count)]
            let b = cameras[Int(generator.next() % count)]
            guard a.id != b.id else { continue }
            let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            if separation.contains(distance) {
                return (a.coordinate, b.coordinate)
            }
        }
        return nil
    }

    /// FNV-1a over the sorted ids. `Hasher` is seeded per process, so it
    /// cannot be used to tell whether two devices swept the same anchor set.
    private static func fingerprint(_ ids: [Int64]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in ids {
            var value = UInt64(bitPattern: id)
            for _ in 0..<8 {
                hash ^= value & 0xff
                hash = hash &* 0x100_0000_01b3
                value >>= 8
            }
        }
        return String(hash, radix: 16)
    }

    // MARK: - Shared

    private func plan(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        level: AvoidanceLevel,
        cameras: [SurveillanceCamera],
        trigger: RoutePlanSample.Trigger,
        speedMps: Double?
    ) async {
        do {
            _ = try await service.timedRouteWithProgressiveAvoidance(
                from: start,
                to: end,
                cameras: cameras,
                useFOV: false,
                level: level,
                trigger: trigger,
                speedMps: speedMps
            )
            lastError = nil
        } catch {
            // The sample is already recorded with its failure reason; this is
            // only so the overlay can show what went wrong.
            lastError = error.localizedDescription
        }
        completed += 1
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
#endif
