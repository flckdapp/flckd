import CoreLocation
import SwiftUI
@preconcurrency import FerrostarCoreFFI

/// The turn card at the top of the driving screen.
///
/// Drawn here rather than with `FerrostarSwiftUI.InstructionsView`, which
/// would otherwise be the obvious choice. Two reasons. Its `ManeuverImage`
/// draws Mapbox's turn glyphs out of Ferrostar's own asset bundle, and the app
/// already has one maneuver icon vocabulary that the route planner's step list
/// and the Live Activity share; a second one on the driving screen would mean
/// the same turn had two pictures. And its row theme is an opaque card with
/// its own type scale, which over this app's floating translucent chrome reads
/// as a second app pasted on top. The content is still entirely Ferrostar's:
/// only the drawing is local.
struct NavigationBannerView: View {

    let instruction: VisualInstruction?
    let distanceToNextManeuver: CLLocationDistance?

    /// Stands in until the first instruction arrives, which is a second or two
    /// after the session starts.
    let fallbackTitle: String

    @AppStorage("useMetric") private var useMetric: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            accentBar

            HStack(spacing: 14) {
                maneuver

                VStack(alignment: .leading, spacing: 3) {
                    Text(primaryText)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)

                    if let secondaryText {
                        Text(secondaryText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        // The accent bar is a shape with only its width fixed, so without
        // this the card takes whatever height the safe-area inset proposes,
        // which on a phone is the whole screen above the progress bar.
        .fixedSize(horizontal: false, vertical: true)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("navigation-banner")
        // Nothing here is tappable, so the map underneath keeps the gesture.
        .allowsHitTesting(false)
    }

    // MARK: - Subviews

    private var accentBar: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        )
        .fill(NavigationPalette.accent)
        .frame(width: 5)
    }

    private var maneuver: some View {
        VStack(spacing: 2) {
            Image(systemName: symbolName)
                .font(.system(size: 32, weight: .semibold))
                .frame(height: 34)

            if let distanceText {
                Text(distanceText)
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
            }
        }
        .frame(minWidth: 62)
    }

    // MARK: - Content

    /// The same table the Live Activity draws from, so the arrow above the
    /// windscreen and the one on the lock screen can't disagree.
    private var maneuverType: ManeuverType? {
        guard let content = instruction?.primaryContent else { return nil }
        return ManeuverType(
            osrmType: content.maneuverType,
            modifier: content.maneuverModifier,
            roundaboutExitDegrees: content.roundaboutExitDegrees
        )
    }

    private var symbolName: String {
        maneuverType?.symbolName ?? "arrow.up.circle.fill"
    }

    private var primaryText: String {
        guard let content = instruction?.primaryContent else { return fallbackTitle }
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        // The engine leaves the text out when it has no street name to put in
        // it, which is common on unnamed slip roads.
        return maneuverType?.displayLabel ?? fallbackTitle
    }

    private var secondaryText: String? {
        var parts: [String] = []
        if let exits = instruction?.primaryContent.exitNumbers, !exits.isEmpty {
            parts.append("Exit \(exits.joined(separator: ", "))")
        }
        if let text = instruction?.secondaryContent?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private var distanceText: String? {
        guard instruction != nil, let distanceToNextManeuver else { return nil }
        return NavigationFormat(useMetric: useMetric).distance(distanceToNextManeuver)
    }

    private var accessibilityText: String {
        [distanceText, primaryText, secondaryText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Previews

#Preview("Turn") {
    ZStack {
        LinearGradient(colors: [.teal.opacity(0.4), .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        VStack {
            NavigationBannerView(
                instruction: VisualInstruction(
                    primaryContent: VisualInstructionContent(
                        text: "Turn right onto Example Avenue",
                        maneuverType: .turn,
                        maneuverModifier: .right,
                        roundaboutExitDegrees: nil,
                        laneInfo: nil,
                        exitNumbers: []
                    ),
                    secondaryContent: nil,
                    subContent: nil,
                    triggerDistanceBeforeManeuver: 100
                ),
                distanceToNextManeuver: 152,
                fallbackTitle: "Starting"
            )
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 8)
    }
}

#Preview("Exit With Secondary") {
    ZStack {
        LinearGradient(colors: [.teal.opacity(0.4), .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        VStack {
            NavigationBannerView(
                instruction: VisualInstruction(
                    primaryContent: VisualInstructionContent(
                        text: "Take the exit toward the test route",
                        maneuverType: .offRamp,
                        maneuverModifier: .slightRight,
                        roundaboutExitDegrees: nil,
                        laneInfo: nil,
                        exitNumbers: ["12B"]
                    ),
                    secondaryContent: VisualInstructionContent(
                        text: "Keep right at the fork",
                        maneuverType: .fork,
                        maneuverModifier: .right,
                        roundaboutExitDegrees: nil,
                        laneInfo: nil,
                        exitNumbers: []
                    ),
                    subContent: nil,
                    triggerDistanceBeforeManeuver: 400
                ),
                distanceToNextManeuver: 1_240,
                fallbackTitle: "Starting"
            )
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 8)
    }
    .preferredColorScheme(.dark)
}

#Preview("Before The First Instruction") {
    ZStack {
        LinearGradient(colors: [.teal.opacity(0.4), .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        VStack {
            NavigationBannerView(
                instruction: nil,
                distanceToNextManeuver: nil,
                fallbackTitle: "Test Destination"
            )
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 8)
    }
}
