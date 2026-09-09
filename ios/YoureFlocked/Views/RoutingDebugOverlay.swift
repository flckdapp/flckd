import SwiftUI
import CoreLocation
import UIKit

/// Field HUD for the reroute-latency spike. Read it while stopped; the probe
/// collects the real data hands-off. Not shippable UI.
struct RoutingDebugOverlay: View {

    let destination: CLLocationCoordinate2D?
    let level: AvoidanceLevel

    @Environment(CameraStore.self) private var cameraStore
    @Environment(LocationManager.self) private var locationManager

    @State private var store = RoutingMetricsStore.shared
    @State private var probe = RerouteProbe.shared
    @State private var isExpanded = true
    @State private var exportFile: ExportFile?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                headline
                Divider().overlay(.white.opacity(0.2))
                sessionStats
                if let error = probe.lastError ?? exportError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                controls
            }
        }
        .padding(12)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: 260)
        .sheet(item: $exportFile) { file in
            ShareSheet(url: file.url)
        }
    }

    private var header: some View {
        HStack {
            Text("ROUTING SPIKE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let sample = store.lastSample {
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.succeeded ? "\(Int(sample.totalMs)) ms" : "FAILED")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(colour(for: sample))

                Text(detailLine(sample))
                    .foregroundStyle(.white.opacity(0.7))

                if let metres = sample.metresTravelledDuringPlan {
                    Text("\(Int(sample.speedMps ?? 0)) m/s → moved \(Int(metres)) m")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        } else {
            Text("No plans yet")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func detailLine(_ sample: RoutePlanSample) -> String {
        var parts: [String] = [sample.trigger.rawValue, sample.level.lowercased()]
        parts.append(sample.engineBuildMs.map { "cold \(Int($0))ms" } ?? "warm")
        parts.append("\(sample.engineCalls) calls")
        if sample.refinementCalls > 0 { parts.append("\(sample.refinementCalls) refine") }
        return parts.joined(separator: " · ")
    }

    private var sessionStats: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                stat("p50", store.p50Ms)
                stat("p95", store.p95Ms)
                stat("max", store.maxMs)
            }
            Text("\(store.samples.count) plans · \(store.failureCount) failed · \(store.coldStartCount) cold")
                .foregroundStyle(.white.opacity(0.7))
            if let fraction = store.withinBudgetFraction {
                Text("\(Int(fraction * 100))% under \(Int(RoutingMetricsStore.drivingBudgetMs)) ms")
                    .foregroundStyle(fraction >= 0.95 ? .green : .orange)
            }
            if let sample = store.lastSample {
                Text("corridor \(sample.corridorCameras) · fenced \(sample.fencedCameras) · seen \(sample.resultExposure)")
                    .foregroundStyle(.white.opacity(0.7))
            }
            if probe.isRunning {
                Text(probeStatus)
                    .foregroundStyle(.cyan)
            }
        }
    }

    private var probeStatus: String {
        switch probe.mode {
        case .drive: return "drive · every \(Int(probe.intervalSeconds))s · \(probe.completed) done"
        case .sweep: return "sweep · \(probe.completed)/\(probe.plannedTotal)"
        }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).foregroundStyle(.white.opacity(0.5))
            Text(value.map { "\(Int($0))" } ?? "–")
                .fontWeight(.semibold)
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button(probe.isRunning ? "Stop" : "Drive") {
                    if probe.isRunning {
                        probe.stop()
                    } else if let destination {
                        probe.startDrive(
                            to: destination,
                            level: level,
                            cameraStore: cameraStore,
                            locationManager: locationManager
                        )
                    }
                }
                .disabled(destination == nil && !probe.isRunning)

                Button("Sweep") {
                    probe.startSweep(level: level, cameraStore: cameraStore)
                }
                .disabled(probe.isRunning)
            }

            HStack(spacing: 6) {
                ForEach([10.0, 20.0, 45.0], id: \.self) { seconds in
                    Button("\(Int(seconds))s") { probe.intervalSeconds = seconds }
                        .overlay {
                            if probe.intervalSeconds == seconds {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.cyan, lineWidth: 1.5)
                            }
                        }
                }
            }

            HStack(spacing: 6) {
                Button("Reset") {
                    store.reset()
                    exportError = nil
                }
                Button("Export") { export() }
                    .disabled(store.samples.isEmpty)
            }
        }
        .buttonStyle(SpikeButtonStyle())
    }

    private func export() {
        do {
            exportFile = ExportFile(url: try store.exportFile())
            exportError = nil
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func colour(for sample: RoutePlanSample) -> Color {
        guard sample.succeeded else { return .red }
        switch sample.totalMs {
        case ..<1000: return .green
        case ..<3000: return .orange
        default: return .red
        }
    }
}

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SpikeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.white.opacity(configuration.isPressed ? 0.3 : 0.15), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.white)
    }
}

    private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // The app targets iPad as well, where an activity controller without a
        // popover anchor raises. Harmless on iPhone.
        controller.popoverPresentationController?.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        controller.popoverPresentationController?.sourceView = controller.view
    }
}
