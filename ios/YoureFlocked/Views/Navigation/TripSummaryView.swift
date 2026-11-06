import SwiftUI

/// What the drive cost, shown once on arrival.
///
/// Every number comes from `NavigationSessionController.TripSummary`, which
/// holds them in memory for exactly as long as this card is on screen. Nothing
/// here is persisted or shared: duration, distance and camera counts together
/// describe a trip.
struct TripSummaryView: View {

    let summary: NavigationSessionController.TripSummary
    let onDone: () -> Void

    @AppStorage("useMetric") private var useMetric: Bool = false

    private var format: NavigationFormat { NavigationFormat(useMetric: useMetric) }

    var body: some View {
        VStack(spacing: 22) {
            header
            statsRow
            camerasSection
            doneButton
        }
        .padding(24)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .padding(.horizontal, 20)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "flag.checkered.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(NavigationPalette.accent)
            Text("You\u{2019}ve arrived")
                .font(.title2.bold())
        }
    }

    private var statsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(format.duration(summary.duration), label: "Duration")
            statDivider
            stat(format.distance(summary.distanceMeters), label: "Distance")
            statDivider
            stat(
                "\(summary.rerouteCount)",
                label: summary.rerouteCount == 1 ? "Reroute" : "Reroutes"
            )
        }
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var statDivider: some View {
        Divider().frame(height: 34)
    }

    private var camerasSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: summary.camerasEncountered == 0 ? "checkmark.shield.fill" : "eye.fill")
                    .foregroundStyle(summary.camerasEncountered == 0 ? NavigationPalette.accent : .orange)
                Text(camerasHeadline)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            if !typeCounts.isEmpty {
                // Wraps rather than squeezing: three chips at the largest
                // accessibility sizes do not fit one line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { typeChips }
                    VStack(spacing: 8) { typeChips }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    @ViewBuilder
    private var typeChips: some View {
        ForEach(typeCounts, id: \.type) { entry in
            HStack(spacing: 5) {
                Image(systemName: entry.type.iconName)
                    .font(.caption)
                Text("\(entry.count) \(entry.type.shortLabel)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
        }
    }

    private var doneButton: some View {
        Button(action: onDone) {
            Text("Done")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(NavigationPalette.accent)
        .accessibilityIdentifier("trip-summary-done")
    }

    // MARK: - Content

    private var camerasHeadline: String {
        switch summary.camerasEncountered {
        case 0: return "No cameras on this trip"
        case 1: return "1 camera encountered"
        default: return "\(summary.camerasEncountered) cameras encountered"
        }
    }

    /// The breakdown the engine counted, in the order the map legend uses.
    /// `otherCount` covers everything that is neither a plate reader nor a
    /// speed camera, so it borrows the generic camera symbol.
    private var typeCounts: [(type: SurveillanceType, count: Int)] {
        [
            (.alpr, summary.alprCount),
            (.speedCamera, summary.speedCount),
            (.camera, summary.otherCount),
        ].filter { $0.count > 0 }
    }
}

// MARK: - Previews

#Preview("Cameras Encountered") {
    ZStack {
        LinearGradient(colors: [.gray.opacity(0.4), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        TripSummaryView(
            summary: NavigationSessionController.TripSummary(
                duration: 28 * 60 + 40,
                distanceMeters: 23_400,
                camerasEncountered: 5,
                alprCount: 3,
                speedCount: 1,
                otherCount: 1,
                rerouteCount: 2
            ),
            onDone: {}
        )
    }
}

#Preview("Clean Trip") {
    ZStack {
        LinearGradient(colors: [.gray.opacity(0.4), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        TripSummaryView(
            summary: NavigationSessionController.TripSummary(
                duration: 72 * 60,
                distanceMeters: 86_000,
                camerasEncountered: 0,
                alprCount: 0,
                speedCount: 0,
                otherCount: 0,
                rerouteCount: 0
            ),
            onDone: {}
        )
    }
    .preferredColorScheme(.dark)
}
