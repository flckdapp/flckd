import ActivityKit
import MapKit
import WidgetKit
import SwiftUI

struct SurveillanceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SurveillanceActivityAttributes.self) { context in
            if context.isStale {
                staleLockScreenView
            } else if context.state.hasNavigation {
                navigationLockScreenView(context: context)
            } else {
                lockScreenView(context: context)
            }
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if context.isStale {
                        HStack(spacing: 6) {
                            Image("WidgetIcon")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .scaleEffect(1.12)
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .opacity(0.5)
                            Text("Paused")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    } else if context.state.hasNavigation {
                        HStack(spacing: 8) {
                            Image(systemName: maneuver(context.state).symbolName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(instructionText(context.state))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image("WidgetIcon")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .scaleEffect(1.12)
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text("\(context.state.nearbyCameraCount)")
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(.white)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale {
                        EmptyView()
                    } else if context.state.hasNavigation {
                        if let turn = turnDistanceLabel(context.state) {
                            Text(turn)
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            if context.state.nearestCameraDistance >= 0 && context.state.nearestCameraDistance < 10_000 {
                                Text(distanceText(context.state.nearestCameraDistance))
                                    .font(.title3.bold().monospacedDigit())
                                    .foregroundStyle(.white)
                                Image(systemName: "location.north.fill")
                                    .rotationEffect(.degrees(context.state.nearestCameraBearing))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Clear")
                                    .font(.title3.bold())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if context.isStale || context.state.hasNavigation {
                        EmptyView()
                    } else {
                        Text(context.state.isTracking ? "Scanning" : "Paused")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        Text("Open app to resume alerts")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else if context.state.hasNavigation {
                        // The camera row stays on screen for the whole trip.
                        // Being warned about a camera is the reason the app is
                        // on the phone; the turn is the newer feature, not the
                        // more important one.
                        cameraSummary(context.state)
                            .padding(.horizontal, 4)
                    } else if context.state.nearbyCameraCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: cameraTypeIcon(context.state.nearestCameraType))
                                .foregroundStyle(cameraTypeColor(context.state.nearestCameraType))
                            Text(context.state.nearestCameraType.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(context.state.nearbyCameraCount) nearby")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                if !context.isStale && context.state.hasNavigation {
                    Image(systemName: maneuver(context.state).symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                } else {
                    Image("WidgetIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.12)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .opacity(context.isStale ? 0.5 : 1.0)
                }
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else if context.state.hasNavigation {
                    if context.state.isRerouting == true {
                        // The word doesn't fit a compact slot; the lock screen
                        // and the expanded island spell it out.
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let turn = turnDistanceLabel(context.state) {
                        Text(turn)
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.white)
                    }
                } else if context.state.nearbyCameraCount > 0 {
                    Text("\(context.state.nearbyCameraCount)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            } minimal: {
                Image("WidgetIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.12)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .opacity(context.isStale ? 0.5 : 1.0)
            }
        }
    }

    // MARK: - Stale Lock Screen

    @ViewBuilder
    private var staleLockScreenView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image("WidgetIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.12)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(0.5)
                    Text("You're Flocked")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Alerts paused — open app to resume")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .activityBackgroundTint(Color(red: 0.133, green: 0.188, blue: 0.239))
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<SurveillanceActivityAttributes>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image("WidgetIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.12)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("You're Flocked")
                        .font(.subheadline.weight(.semibold))
                }

                if context.state.nearbyCameraCount > 0 {
                    Text("\(context.state.nearbyCameraCount) camera\(context.state.nearbyCameraCount == 1 ? "" : "s") nearby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No cameras in range")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if context.state.nearbyCameraCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(distanceText(context.state.nearestCameraDistance))
                        .font(.title3.bold().monospacedDigit())
                    Text("nearest")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .activityBackgroundTint(Color(red: 0.133, green: 0.188, blue: 0.239))
    }

    // MARK: - Navigation Lock Screen

    /// Two rows that are both always there: the turn on top because it is the
    /// thing the driver is about to do, the camera warning under it because it
    /// is the thing they installed the app for.
    @ViewBuilder
    private func navigationLockScreenView(
        context: ActivityViewContext<SurveillanceActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: maneuver(context.state).symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, alignment: .center)

                Text(instructionText(context.state))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                if let turn = turnDistanceLabel(context.state) {
                    Text(turn)
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.25))

            HStack(spacing: 8) {
                Image("WidgetIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.12)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                cameraSummary(context.state)

                Spacer(minLength: 8)

                if let eta = context.state.eta {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.checkered")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(eta, style: .time)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(16)
        .activityBackgroundTint(Color(red: 0.133, green: 0.188, blue: 0.239))
    }

    /// The camera half of a navigating layout, in one line.
    @ViewBuilder
    private func cameraSummary(_ state: SurveillanceActivityAttributes.ContentState) -> some View {
        HStack(spacing: 5) {
            if state.nearbyCameraCount > 0 {
                Image(systemName: cameraTypeIcon(state.nearestCameraType))
                    .font(.caption)
                    .foregroundStyle(cameraTypeColor(state.nearestCameraType))
                Text("\(state.nearbyCameraCount) camera\(state.nearbyCameraCount == 1 ? "" : "s") nearby")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                if state.nearestCameraDistance >= 0 {
                    Text(localizedDistanceText(state.nearestCameraDistance))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("No cameras in range")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    // MARK: - Helpers

    private func maneuver(_ state: SurveillanceActivityAttributes.ContentState) -> ManeuverType {
        guard let code = state.nextManeuverCode else { return .unknown }
        return ManeuverType(code: code)
    }

    /// Ferrostar's banner text when there is one, and the maneuver's own label
    /// when there isn't, so the row never renders blank.
    private func instructionText(_ state: SurveillanceActivityAttributes.ContentState) -> String {
        guard let instruction = state.nextManeuverInstruction, !instruction.isEmpty else {
            return maneuver(state).displayLabel
        }
        return instruction
    }

    /// What goes where the distance to the turn goes. A reroute takes the slot:
    /// the old distance is to a turn that is no longer on the route.
    private func turnDistanceLabel(_ state: SurveillanceActivityAttributes.ContentState) -> String? {
        if state.isRerouting == true { return "Rerouting…" }
        guard let meters = state.distanceToNextTurnMeters else { return nil }
        return localizedDistanceText(meters)
    }

    private func distanceText(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1fkm", meters / 1000)
        }
        return "\(Int(meters))m"
    }

    /// A distance in the units of the device's region.
    ///
    /// The app's own metric/imperial setting is in `UserDefaults.standard`,
    /// which this extension cannot read: the app and the widget share no App
    /// Group, and adding one is an entitlement change. `MKDistanceFormatter`
    /// follows the region instead, which agrees with the setting for anyone who
    /// left it alone and is only wrong for someone who deliberately overrode it.
    /// Used for the navigating layout; `distanceText` keeps the
    /// camera-only layout rendering exactly as it did before turns existed.
    private func localizedDistanceText(_ meters: Double) -> String {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        formatter.units = .default
        return formatter.string(fromDistance: max(0, meters))
    }

    private func cameraTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "alpr": return "car.fill"
        case "speed_camera": return "speedometer"
        default: return "video.fill"
        }
    }

    private func cameraTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "alpr": return .red
        case "speed_camera": return .yellow
        default: return .orange
        }
    }
}

// MARK: - Previews

extension SurveillanceActivityAttributes.ContentState {

    /// What an activity started before turns existed decodes to: every
    /// navigation field absent.
    fileprivate static let previewCameraOnly = Self(
        nearbyCameraCount: 2,
        nearestCameraDistance: 180,
        nearestCameraBearing: 45,
        nearestCameraType: "alpr",
        isTracking: true
    )

    fileprivate static let previewNavigating = Self(
        nearbyCameraCount: 3,
        nearestCameraDistance: 240,
        nearestCameraBearing: 310,
        nearestCameraType: "speed_camera",
        isTracking: true,
        nextManeuverCode: ManeuverType.right.rawValue,
        nextManeuverInstruction: "Turn right onto Test Street",
        distanceToNextTurnMeters: 400,
        eta: Date(timeIntervalSinceReferenceDate: 800_000_000),
        isRerouting: false
    )

    fileprivate static let previewRerouting = Self(
        nearbyCameraCount: 0,
        nearestCameraDistance: -1,
        nearestCameraBearing: 0,
        nearestCameraType: "",
        isTracking: true,
        nextManeuverCode: ManeuverType.roundaboutEnter.rawValue,
        nextManeuverInstruction: "Enter the roundabout",
        distanceToNextTurnMeters: 120,
        eta: Date(timeIntervalSinceReferenceDate: 800_000_000),
        isRerouting: true
    )
}

#Preview("Lock Screen", as: .content, using: SurveillanceActivityAttributes(alertRadius: 200)) {
    SurveillanceLiveActivity()
} contentStates: {
    SurveillanceActivityAttributes.ContentState.previewCameraOnly
    SurveillanceActivityAttributes.ContentState.previewNavigating
    SurveillanceActivityAttributes.ContentState.previewRerouting
}

#Preview("Island — Expanded", as: .dynamicIsland(.expanded), using: SurveillanceActivityAttributes(alertRadius: 200)) {
    SurveillanceLiveActivity()
} contentStates: {
    SurveillanceActivityAttributes.ContentState.previewCameraOnly
    SurveillanceActivityAttributes.ContentState.previewNavigating
    SurveillanceActivityAttributes.ContentState.previewRerouting
}

#Preview("Island — Compact", as: .dynamicIsland(.compact), using: SurveillanceActivityAttributes(alertRadius: 200)) {
    SurveillanceLiveActivity()
} contentStates: {
    SurveillanceActivityAttributes.ContentState.previewCameraOnly
    SurveillanceActivityAttributes.ContentState.previewNavigating
    SurveillanceActivityAttributes.ContentState.previewRerouting
}
