#if DEBUG
import Darwin
import SwiftUI
import UIKit

/// Measures Kokoro on this phone: load time, render speed per preset, memory
/// footprint and heat, and a 30-minute render loop to run beside a simulated
/// drive. Debug builds only; the report is shared by hand and holds no text
/// other than the ten fixed generic sentences below.
struct KokoroBenchView: View {
    static let sentences = [
        "Turn left.",
        "In five hundred feet, turn right.",
        "In a quarter mile, turn left onto Main Street.",
        "In half a mile, turn right onto Oak Avenue.",
        "In one mile, take the exit on the right onto Interstate nine ninety nine.",
        "In two miles, keep left to take Highway nine ninety nine.",
        "In one thousand feet, bear right onto North Park Road.",
        "In a quarter mile, at the roundabout, take the second exit onto Example Boulevard.",
        "In a quarter mile, turn left onto East Thirty Ninth Street.",
        "Flock camera ahead.",
    ]
    nonisolated static let benchFolder = "kokoro-bench-model"

    /// Session-scoped, so the loop keeps running while you switch to the driving screen.
    private let bench = KokoroBench.shared
    @State private var useBenchFolder = false
    @State private var shareURL: URL?

    var body: some View {
        Form {
            Section {
                Toggle("Bench model folder", isOn: $useBenchFolder)
                    .disabled(bench.running)
                Text(useBenchFolder
                     ? "Loads Documents/\(Self.benchFolder) without the pack's size and hash checks."
                     : "Loads the installed street-name engine.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Model")
            }
            Section {
                Button("Single renders, all presets") { bench.runSingles(benchFolder: useBenchFolder) }
                Button(bench.looping ? "Stop 30-minute loop" : "Start 30-minute loop") {
                    bench.looping ? bench.stopLoop() : bench.startLoop(benchFolder: useBenchFolder)
                }
                Button("Export report") { shareURL = try? bench.exportReport() }
            }
            .disabled(bench.running && !bench.looping)
            Section("Status") {
                Text(bench.status).font(.caption.monospaced())
                    .accessibilityIdentifier("kokoro-bench-status")
                if let footprint = bench.lastFootprint {
                    Text("Footprint now \(KokoroBench.megabytes(footprint)), thermal \(KokoroBench.name(ProcessInfo.processInfo.thermalState))")
                        .font(.caption.monospaced())
                }
            }
            Section("Results") {
                ForEach(bench.lines.indices, id: \.self) { index in
                    Text(bench.lines[index]).font(.caption2.monospaced())
                }
            }
        }
        .navigationTitle("Kokoro Bench")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { shareURL.map(SharedFile.init) }, set: { shareURL = $0?.url })) { file in
            ShareLink(item: file.url) { Label("Share report", systemImage: "square.and.arrow.up") }
                .padding()
                .presentationDetents([.height(120)])
        }
    }

    private struct SharedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

/// The bench's work, off the main thread on its own synthesizer.
@MainActor
@Observable
final class KokoroBench {
    static let shared = KokoroBench()

    /// Read on the synthesizer queue right before each loop render: like the
    /// app's own renderer, the bench never starts a render in the background.
    @ObservationIgnored private let foreground = Foreground()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    final class Foreground: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
        func set(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    }

    private init() {
        let foreground = foreground
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in foreground.set(true) })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in foreground.set(false) })
    }
    private(set) var lines: [String] = []
    private(set) var status = "Idle"
    private(set) var running = false
    private(set) var looping = false
    private(set) var lastFootprint: UInt64?
    private var report: [String] = []
    private var loopTask: Task<Void, Never>?

    nonisolated static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    nonisolated static func megabytes(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

    nonisolated static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    nonisolated private static func factory(benchFolder: Bool) -> KokoroSynthesizer.Factory {
        guard benchFolder else { return KokoroSynthesizer.standardFactory }
        return {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
            let dir = documents.appendingPathComponent(KokoroBenchView.benchFolder)
            func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
            let paths = KokoroVoiceStore.ModelPaths(model: path("model.onnx"), voices: path("voices.bin"),
                                                    tokens: path("tokens.txt"), lexicon: path("lexicon-us-en.txt"))
            guard let lexicon = KokoroLexicon(contentsOfFile: paths.lexicon),
                  let engine = SherpaKokoroEngine(paths: paths) else { return nil }
            return (engine, lexicon)
        }
    }

    private func log(_ line: String) {
        lines.append(line)
        report.append(line)
    }

    private func header(_ title: String, benchFolder: Bool) {
        log("== \(title) \(Date().formatted(date: .omitted, time: .standard)), model: \(benchFolder ? "bench folder" : KokoroPackDescriptor.bundled?.id ?? "?"), thermal \(Self.name(ProcessInfo.processInfo.thermalState))")
    }

    func runSingles(benchFolder: Bool) {
        guard !running else { return }
        running = true
        status = "Loading"
        header("Single renders", benchFolder: benchFolder)
        let synthesizer = KokoroSynthesizer(factory: Self.factory(benchFolder: benchFolder))
        let presets = KokoroPreset.all()
        let sentences = KokoroBenchView.sentences
        synthesizer.queue.async { [weak self] in
            let before = Self.footprint() ?? 0
            let start = ProcessInfo.processInfo.systemUptime
            let loaded = synthesizer.loadOnQueue()
            let loadTime = ProcessInfo.processInfo.systemUptime - start
            let afterLoad = Self.footprint() ?? 0
            var peak = afterLoad
            var rows: [String] = []
            if loaded, let lexicon = synthesizer.lexicon {
                for preset in presets {
                    for (index, sentence) in sentences.enumerated() {
                        let t0 = ProcessInfo.processInfo.systemUptime
                        let result = synthesizer.render(sentence, preset: preset, knows: lexicon.knows)
                        let elapsed = ProcessInfo.processInfo.systemUptime - t0
                        peak = max(peak, Self.footprint() ?? 0)
                        if let result {
                            let audio = Double(result.samples.count) / KokoroSynthesizer.outputRate
                            rows.append(String(format: "%@ #%2d render %.2f s audio %.2f s RTF %.2f", preset.id, index + 1, elapsed, audio, result.rtf))
                        } else {
                            rows.append("\(preset.id) #\(index + 1) failed (word check or engine)")
                        }
                    }
                }
            }
            synthesizer.unloadOnQueue()
            let afterUnload = Self.footprint() ?? 0
            let thermal = Self.name(ProcessInfo.processInfo.thermalState)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log(loaded ? String(format: "load %.2f s", loadTime) : "load FAILED")
                rows.forEach(self.log)
                self.log("footprint before \(Self.megabytes(before)), after load \(Self.megabytes(afterLoad)), sampled peak (after each render) \(Self.megabytes(peak)), after unload \(Self.megabytes(afterUnload)), thermal \(thermal)")
                self.lastFootprint = afterUnload
                self.status = "Done"
                self.running = false
            }
        }
    }

    func startLoop(benchFolder: Bool) {
        guard !running else { return }
        running = true
        looping = true
        header("30-minute loop, one render every 10 s", benchFolder: benchFolder)
        let synthesizer = KokoroSynthesizer(factory: Self.factory(benchFolder: benchFolder))
        let preset = KokoroPreset.named(UserDefaults.standard.string(forKey: KokoroPreset.storageKey) ?? KokoroPreset.defaultID)
            ?? KokoroPreset.all().first
        let foreground = foreground
        loopTask = Task { [weak self] in
            guard let preset else { return }
            let end = Date().addingTimeInterval(30 * 60)
            var index = 0
            var renders: [Double] = []
            var peak: UInt64 = 0
            var lastThermal = ""
            while !Task.isCancelled, Date() < end {
                let sentence = KokoroBenchView.sentences[index % KokoroBenchView.sentences.count]
                // nil: failed; (-1, -1): skipped because the app was not in the foreground.
                let outcome: (Double, Double)? = await withCheckedContinuation { continuation in
                    synthesizer.queue.async {
                        guard foreground.isActive else {
                            continuation.resume(returning: (-1, -1))
                            return
                        }
                        guard synthesizer.loadOnQueue(), let lexicon = synthesizer.lexicon else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let t0 = ProcessInfo.processInfo.systemUptime
                        let result = synthesizer.render(sentence, preset: preset, knows: lexicon.knows)
                        continuation.resume(returning: result.map { (ProcessInfo.processInfo.systemUptime - t0, $0.rtf) })
                    }
                }
                let footprint = Self.footprint() ?? 0
                peak = max(peak, footprint)
                let thermal = Self.name(ProcessInfo.processInfo.thermalState)
                let skipped = outcome.map { $0.0 < 0 } ?? false
                if let outcome, !skipped { renders.append(outcome.0) }
                let line = skipped ? "#\(index + 1) skipped: app not in the foreground, footprint \(Self.megabytes(footprint))"
                    : outcome.map { String(format: "#%d render %.2f s RTF %.2f, footprint %@, thermal %@", index + 1, $0.0, $0.1, Self.megabytes(footprint), thermal) }
                    ?? "#\(index + 1) failed"
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.status = line
                    self.lastFootprint = footprint
                    if thermal != lastThermal || (index + 1) % 30 == 0 || outcome == nil || skipped { self.log(line) }
                }
                lastThermal = thermal
                index += 1
                try? await Task.sleep(for: .seconds(10))
            }
            synthesizer.unload()
            let sorted = renders.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            let summary = String(format: "loop: %d renders, median %.2f s, p90 %.2f s, sampled peak footprint %@", renders.count, median, p90, Self.megabytes(peak))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.log(summary)
                self.status = "Loop finished"
                self.looping = false
                self.running = false
            }
        }
    }

    func stopLoop() {
        loopTask?.cancel()
    }

    /// Writes the session as text for the share sheet. The sentinel string
    /// ties this file to the Release check: if this view's `#if DEBUG` were
    /// removed, the Release build would fail.
    func exportReport() throws -> URL {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let text = ([
            "diagnosticsBuild: \(RoutingMetricsStore.buildSentinel)",
            "device: \(machine), memory \(Self.megabytes(ProcessInfo.processInfo.physicalMemory))",
            "system: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "lowPowerMode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)",
            "sentences:",
        ] + KokoroBenchView.sentences.enumerated().map { "  #\($0.offset + 1) \($0.element)" } + [""] + report)
            .joined(separator: "\n")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flckd-kokoro-bench-\(stamp).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
#endif
