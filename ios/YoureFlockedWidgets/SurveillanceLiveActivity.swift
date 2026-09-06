import ActivityKit
import WidgetKit
import SwiftUI

struct SurveillanceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SurveillanceActivityAttributes.self) { context in
            if context.isStale {
                staleLockScreenView
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
                    if !context.isStale {
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
                    if context.isStale {
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
                Image("WidgetIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.12)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .opacity(context.isStale ? 0.5 : 1.0)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
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

    // MARK: - Helpers

    private func distanceText(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1fkm", meters / 1000)
        }
        return "\(Int(meters))m"
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
