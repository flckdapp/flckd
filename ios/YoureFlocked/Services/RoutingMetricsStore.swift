import Foundation
import os

/// Collects `RoutePlanSample`s during a field test and exports them.
///
/// This exists to answer one question: can a camera-avoiding reroute finish
/// fast enough to be useful to a moving car? Nothing here affects routing
/// behaviour; the store is written to as a side effect of planning and read
/// only by the debug overlay.
@MainActor
@Observable
final class RoutingMetricsStore {

    static let shared = RoutingMetricsStore()

    /// Roughly how long a reroute may take before the driver has already
    /// passed the junction it would have changed. Used only to colour the
    /// overlay; nothing branches on it.
    static let drivingBudgetMs: Double = 2000

    private static let log = Logger(subsystem: "io.vws.app.flckd", category: "routing.metrics")

    private(set) var samples: [RoutePlanSample] = []

    /// Set by `RerouteProbe` when a sweep starts; travels in the export so a
    /// cross-device comparison can be checked rather than assumed.
    var sweepContext: SweepContext?

    /// Cap the session so a long drive can't grow memory without bound.
    /// 2000 samples at a 20 s cadence is over eleven hours of driving.
    private let maxSamples = 2000

    private init() {}

    // MARK: - Recording

    func record(_ sample: RoutePlanSample) {
        samples.append(sample)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }

        // Mirror into the unified log so a drive can be recovered with
        // `log collect` even if the app is killed before export. Counts and
        // durations are marked public; there is nothing here to redact.
        Self.log.info("""
            plan \(sample.trigger.rawValue, privacy: .public) \
            level=\(sample.level, privacy: .public) \
            total=\(Int(sample.totalMs), privacy: .public)ms \
            engine=\(Int(sample.engineMsTotal), privacy: .public)ms \
            max=\(Int(sample.engineMsMax), privacy: .public)ms \
            scoring=\(Int(sample.scoringMsTotal), privacy: .public)ms \
            build=\(sample.engineBuildMs.map { String(Int($0)) } ?? "warm", privacy: .public) \
            calls=\(sample.engineCalls, privacy: .public) \
            refine=\(sample.refinementCalls, privacy: .public) \
            corridor=\(sample.corridorCameras, privacy: .public) \
            fenced=\(sample.fencedCameras, privacy: .public) \
            exposure=\(sample.resultExposure, privacy: .public) \
            fail=\(sample.failure ?? "-", privacy: .public)
            """)
    }

    func reset() {
        samples.removeAll()
    }

    // MARK: - Session statistics

    var lastSample: RoutePlanSample? { samples.last }

    var successCount: Int { samples.lazy.filter(\.succeeded).count }
    var failureCount: Int { samples.count - successCount }
    var coldStartCount: Int { samples.lazy.filter { $0.engineBuildMs != nil }.count }

    /// Percentiles over successful plans only. A failed plan's duration says
    /// nothing about how long a usable reroute takes.
    private var successfulDurations: [Double] {
        samples.lazy.filter(\.succeeded).map(\.totalMs).sorted()
    }

    var p50Ms: Double? { percentile(0.50) }
    var p95Ms: Double? { percentile(0.95) }
    var maxMs: Double? { successfulDurations.last }

    private func percentile(_ p: Double) -> Double? {
        let values = successfulDurations
        guard !values.isEmpty else { return nil }
        let rank = Int((p * Double(values.count)).rounded(.up)) - 1
        return values[min(max(rank, 0), values.count - 1)]
    }

    /// Share of successful plans that landed inside the driving budget.
    var withinBudgetFraction: Double? {
        let values = successfulDurations
        guard !values.isEmpty else { return nil }
        let inside = values.lazy.filter { $0 <= Self.drivingBudgetMs }.count
        return Double(inside) / Double(values.count)
    }

    // MARK: - Export

    /// Writes the session to a JSON file and returns it for `ShareLink`.
    ///
    /// The payload is safe to send: it holds durations, counts, a hardware
    /// identifier and the size of the installed region pack. It does not hold
    /// coordinates or the region's name. Pack size is included because graph
    /// scale is the main thing outside timing that explains latency, and a
    /// byte count names no place.
    func exportFile() throws -> URL {
        let payload = Export(
            exportedAt: Date(),
            device: Self.hardwareIdentifier(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            regionPackBytes: Self.installedRegionBytes(),
            drivingBudgetMs: Self.drivingBudgetMs,
            sweepContext: sweepContext,
            summary: Export.Summary(
                plans: samples.count,
                succeeded: successCount,
                failed: failureCount,
                coldStarts: coldStartCount,
                p50Ms: p50Ms,
                p95Ms: p95Ms,
                maxMs: maxMs,
                withinBudgetFraction: withinBudgetFraction
            ),
            samples: samples
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flckd-routing-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private struct Export: Codable {
        struct Summary: Codable {
            let plans: Int
            let succeeded: Int
            let failed: Int
            let coldStarts: Int
            let p50Ms: Double?
            let p95Ms: Double?
            let maxMs: Double?
            let withinBudgetFraction: Double?
        }

        let exportedAt: Date
        let device: String
        let systemVersion: String
        let appVersion: String
        let regionPackBytes: Int64?
        let drivingBudgetMs: Double
        let sweepContext: SweepContext?
        let summary: Summary
        let samples: [RoutePlanSample]
    }

    /// e.g. "iPhone16,2". CPU generation dominates these measurements, so the
    /// model identifier is worth more than `UIDevice.model`'s "iPhone".
    private static func hardwareIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        var machine = info.machine
        return withUnsafeBytes(of: &machine) { raw in
            guard let base = raw.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Size of the region pack routing would use. Scale without identity.
    private static func installedRegionBytes() -> Int64? {
        guard let url = RegionStore.bestAvailableRegion() else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}
