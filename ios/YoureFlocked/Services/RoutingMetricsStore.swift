#if DEBUG
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

    private var handle: FileHandle?

    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let lineDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        recoverSession()
    }

    // MARK: - Recording

    func record(_ sample: RoutePlanSample) {
        samples.append(sample)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        persist(sample)

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
        sweepContext = nil
        do {
            try handle?.close()
            handle = nil
            let url = try Self.sessionURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            Self.log.error("reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Durability

    /// Samples are appended as JSON lines the moment they are recorded.
    ///
    /// An hour of continuous GPS, MapKit and Valhalla on a 4 GB device makes
    /// termination likely rather than hypothetical. An in-memory-only session
    /// would lose the entire drive at exactly the point the data became
    /// interesting, so every sample hits disk before the next one is planned.
    private static func sessionURL() throws -> URL {
        let directory = URL.applicationSupportDirectory
            .appending(path: "routing-spike", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "session.jsonl")
    }

    private func persist(_ sample: RoutePlanSample) {
        do {
            if handle == nil {
                let url = try Self.sessionURL()
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let opened = try FileHandle(forWritingTo: url)
                let end = try opened.seekToEnd()
                // A run killed mid-write leaves a fragment with no terminator.
                // Appending straight onto it merges the fragment and the next
                // sample into one unparseable line, losing a good sample as
                // well as the fragment. Close the boundary first.
                if end > 0 {
                    try opened.seek(toOffset: end - 1)
                    if try opened.read(upToCount: 1) != Data([0x0A]) {
                        try opened.write(contentsOf: Data([0x0A]))
                    }
                }
                handle = opened
            }
            var line = try Self.lineEncoder.encode(sample)
            line.append(0x0A)
            try handle?.write(contentsOf: line)
        } catch {
            Self.log.error("persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recoverSession() {
        do {
            let url = try Self.sessionURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            var recovered: [RoutePlanSample] = []
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                // A kill part-way through a write leaves a truncated trailing
                // line. Skipping it recovers the rest of the drive instead of
                // throwing the whole session away.
                guard let sample = try? Self.lineDecoder.decode(RoutePlanSample.self, from: Data(line)) else {
                    continue
                }
                recovered.append(sample)
            }
            samples = Array(recovered.suffix(maxSamples))
            if !recovered.isEmpty {
                Self.log.info("recovered \(recovered.count, privacy: .public) samples from a previous session")
            }
        } catch {
            Self.log.error("recovery failed: \(error.localizedDescription, privacy: .public)")
        }
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

    /// Share of *all* attempts that both succeeded and landed inside the
    /// budget. Scoring only successful plans flatters the result: a reroute
    /// that fails is a reroute the driver did not get, not a sample to drop.
    var withinBudgetFraction: Double? {
        guard !samples.isEmpty else { return nil }
        let met = samples.lazy.filter { $0.succeeded && $0.totalMs <= Self.drivingBudgetMs }.count
        return Double(met) / Double(samples.count)
    }

    // MARK: - Export

    /// Writes the session to a JSON file and returns it for the share sheet.
    ///
    /// Holds no coordinates, but do not mistake that for anonymous: pack size
    /// resolves to a state against the public tile manifest, and timestamps
    /// plus speed plus remaining distance describe the trip. Fine for the
    /// developer's own device, which is the only place this compiles.
    func exportFile() throws -> URL {
        let payload = Export(
            exportedAt: Date(),
            device: Self.hardwareIdentifier(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            installedRegionCount: RegionStore.installedRegions().count,
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
        let installedRegionCount: Int
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
}
#endif
