import Foundation

/// One timed run of `ValhallaRoutingService.routeWithProgressiveAvoidance`.
///
/// Deliberately carries no coordinates: not the endpoints, not the camera
/// positions, not the route shape, not the name of the downloaded region.
/// These samples exist to be exported off the device and shared, and
/// AGENTS.md forbids anything in a shareable artefact that identifies where a
/// real person drives. Durations, counts and scalars only.
///
/// `speedMps` is a scalar magnitude with no bearing and no position, so it
/// identifies no place. It is here because reroute latency only matters
/// relative to how fast the car was moving when planning started.
struct RoutePlanSample: Codable, Identifiable, Sendable {

    enum Trigger: String, Codable, Sendable {
        /// The user picked a destination.
        case initial
        /// The detour re-run inside `routeToPlace` when the route left the corridor.
        case recheck
        /// "Replan now" in the debug overlay.
        case manual
        /// The auto-reroute probe's timer, driving.
        case auto
        /// A synthetic pair from the stationary sweep.
        case sweep
    }

    let id: UUID
    let timestamp: Date
    let trigger: Trigger
    let level: String

    // MARK: Timings (milliseconds)

    /// Wall time for the whole progressive-avoidance call. This is the number
    /// that decides feasibility: it is what a driver would wait for a reroute.
    let totalMs: Double
    /// Blocking time inside the Valhalla engine, summed across every call.
    let engineMsTotal: Double
    /// The slowest single engine call in this plan.
    let engineMsMax: Double
    /// Time spent scoring candidates with `exposedCameraIDs`.
    let scoringMsTotal: Double
    /// Non-nil when the engine had to be constructed during this plan
    /// (mmap, index parse, tzdata extraction). Happens on first use and after
    /// every background teardown, so it is the cost of the first reroute
    /// after the phone has been idle.
    let engineBuildMs: Double?

    // MARK: Call counts

    /// Engine calls made by the progressive-avoidance loop: baseline, one per
    /// radius rung, plus refinements.
    let engineCalls: Int
    /// How many of `engineCalls` were greedy re-fencing refinements.
    let refinementCalls: Int
    /// Candidates admitted to the scoring pool, primaries plus alternates.
    let candidatesScored: Int

    // MARK: Inputs and outcome

    let corridorCameras: Int
    let fencedCameras: Int
    /// Cameras within the scoring radius of the winning route.
    let resultExposure: Int
    let routeKm: Double
    let routeMinutes: Double
    /// Ground speed when planning started, when Core Location reported a
    /// valid one.
    let speedMps: Double?
    /// Size of the region pack this plan actually routed against. Graph scale
    /// is the main non-CPU explanation for latency, and on a device with
    /// several packs installed the one in use is not the largest one present.
    /// A byte count names no place.
    let regionBytes: Int64?
    /// Thermal state when planning started. An A14 in a windscreen mount
    /// throttles hard enough to move these numbers, and that is a real
    /// driving condition rather than a measurement artefact.
    let thermalState: String
    /// Nil on success; the `RoutingError` case name on failure.
    let failure: String?

    var succeeded: Bool { failure == nil }

    /// Metres covered while the plan was being computed. The honest measure
    /// of whether a reroute can land before the driver passes the decision
    /// point it was meant to change.
    var metresTravelledDuringPlan: Double? {
        guard let speedMps, speedMps > 0 else { return nil }
        return speedMps * (totalMs / 1000)
    }
}

/// How long a single engine call took, and whether it paid for construction.
struct EngineTiming: Sendable {
    /// Non-nil when the `Valhalla` instance was built for this call.
    let buildMs: Double?
    /// The blocking `Valhalla.route(rawRequest:)` call itself.
    let callMs: Double

    static let zero = EngineTiming(buildMs: nil, callMs: 0)
}

/// Accumulates timings across the many engine calls a single plan makes.
///
/// A reference type so the totals survive a thrown error: a plan that fails
/// burns the most engine calls, which is exactly the case worth measuring.
/// Confined to one `ValhallaRoutingService` call chain, so it needs no
/// locking.
final class RoutePlanAccumulator {
    private(set) var engineMsTotal: Double = 0
    private(set) var engineMsMax: Double = 0
    private(set) var scoringMsTotal: Double = 0
    private(set) var engineBuildMs: Double?
    private(set) var engineCalls: Int = 0
    private(set) var refinementCalls: Int = 0
    private(set) var candidatesScored: Int = 0

    var corridorCameras: Int = 0
    var fencedCameras: Int = 0
    var regionBytes: Int64?

    func addEngineCall(_ timing: EngineTiming, isRefinement: Bool = false) {
        engineCalls += 1
        if isRefinement { refinementCalls += 1 }
        engineMsTotal += timing.callMs
        engineMsMax = Swift.max(engineMsMax, timing.callMs)
        // Construction happens at most once per plan; keep the first.
        if engineBuildMs == nil { engineBuildMs = timing.buildMs }
    }

    func addScoring(_ ms: Double, candidates: Int) {
        scoringMsTotal += ms
        candidatesScored += candidates
    }
}

/// Identifies which synthetic pairs a sweep planned, so a run on one device
/// can be compared against a run on another. Two exports are comparable only
/// when the seed and the fingerprint both match.
struct SweepContext: Codable, Sendable {
    let seed: UInt64
    let anchorCount: Int
    let anchorFingerprint: String
}

/// SplitMix64. Reproducible across devices and OS versions, which
/// `SystemRandomNumberGenerator` is explicitly not.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension ProcessInfo.ThermalState {
    var exportName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Monotonic millisecond stopwatch. `ContinuousClock` keeps counting while
/// the device is asleep, which matters for measurements taken in a car.
struct Stopwatch {
    private let start = ContinuousClock.now

    var elapsedMs: Double {
        let d = ContinuousClock.now - start
        let (seconds, attoseconds) = d.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
