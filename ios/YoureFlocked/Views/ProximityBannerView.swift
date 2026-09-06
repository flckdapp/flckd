import SwiftUI
import CoreLocation

// MARK: - Proximity Banner View

/// Non-modal, glanceable proximity alert banner for driving context.
/// Renders above the map, auto-updates with distance/direction, and does not block interaction.
///
/// Layout: [accent bar] [type icon + label] | [distance] | [direction arrow + label] [+N badge]
/// Background: translucent material capsule matching the app's floating control style.
struct ProximityBannerView: View {
    let alert: MapViewModel.ProximityAlert
    var tripStats: MapViewModel.TripStats = .init()
    @AppStorage("useMetric") private var useMetric: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            accentBar

            HStack(spacing: 14) {
                typeSection

                Spacer(minLength: 0)

                distanceSection

                Spacer(minLength: 0)

                directionSection

                if alert.nearbyCount > 0 {
                    nearbyBadge
                }

                if tripStats.totalCount > 0 {
                    tripBadge
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
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
        .fill(accentColor)
        .frame(width: 5)
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: alert.camera.surveillanceType.iconName)
                .font(.body.bold())
                .foregroundStyle(accentColor)
            Text(alert.camera.surveillanceType.shortLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 44)
    }

    private var distanceSection: some View {
        Text(formattedDistance)
            .font(.title2.bold().monospacedDigit())
            .contentTransition(.numericText())
            .foregroundStyle(.primary)
    }

    private var directionSection: some View {
        Group {
            if alert.relativeDirection != .nearby, alert.relativeBearing != nil {
                VStack(spacing: 2) {
                    Image(systemName: "location.north.fill")
                        .font(.body)
                        .rotationEffect(.degrees(alert.relativeBearing ?? 0))
                        .animation(.easeInOut(duration: 0.2), value: alert.relativeBearing)
                    Text(alert.relativeDirection.rawValue)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
            } else {
                Text("Nearby")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nearbyBadge: some View {
        Text("+\(alert.nearbyCount)")
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary)
            .clipShape(Capsule())
    }

    private var tripBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye")
                .font(.system(size: 9))
            Text("\(tripStats.totalCount)")
                .font(.caption2.bold().monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary)
        .clipShape(Capsule())
    }

    // MARK: - Formatting

    private var formattedDistance: String {
        if useMetric {
            let meters = Int(alert.distance)
            if meters >= 1000 {
                return String(format: "%.1f km", alert.distance / 1000)
            }
            return "\(meters) m"
        } else {
            let feet = alert.distance * 3.28084
            if feet >= 5280 {
                return String(format: "%.1f mi", feet / 5280)
            }
            return "\(Int(feet)) ft"
        }
    }

    private var accentColor: Color {
        switch alert.camera.surveillanceType {
        case .alpr: return .red
        case .camera: return .orange
        case .speedCamera: return .yellow
        case .gunshotDetector: return .purple
        default: return .gray
        }
    }
}

// MARK: - Preview

#Preview("ALPR Alert — Ahead") {
    ZStack {
        Color.black.opacity(0.2)
            .ignoresSafeArea()

        VStack {
            ProximityBannerView(
                alert: MapViewModel.ProximityAlert(
                    cameraID: 12345,
                    camera: SurveillanceCamera(
                        osmID: 12345,
                        latitude: 37.7749,
                        longitude: -122.4194,
                        tags: ["surveillance:type": "ALPR", "manufacturer": "Flock Safety"]
                    ),
                    distance: 142,
                    bearing: 45,
                    relativeBearing: 15,
                    relativeDirection: .ahead,
                    nearbyCount: 2,
                    enteredAt: Date(),
                    hasTriggeredVeryClose: false
                )
            )
            .transition(.move(edge: .top).combined(with: .opacity))

            Spacer()
        }
        .padding(.top, 8)
    }
}

#Preview("Speed Camera — No Heading") {
    ZStack {
        Color.black.opacity(0.2)
            .ignoresSafeArea()

        VStack {
            ProximityBannerView(
                alert: MapViewModel.ProximityAlert(
                    cameraID: 67890,
                    camera: SurveillanceCamera(
                        osmID: 67890,
                        latitude: 37.78,
                        longitude: -122.42,
                        tags: ["surveillance:type": "speed_camera"]
                    ),
                    distance: 48,
                    bearing: 200,
                    relativeBearing: nil,
                    relativeDirection: .nearby,
                    nearbyCount: 0,
                    enteredAt: Date(),
                    hasTriggeredVeryClose: true
                )
            )

            Spacer()
        }
        .padding(.top, 8)
    }
}
