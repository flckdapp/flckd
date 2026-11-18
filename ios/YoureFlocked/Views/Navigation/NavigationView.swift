import CoreLocation
import MapKit
import SwiftUI
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// Everything the driving screen draws, lifted out of the session.
///
/// A plain value rather than the controller itself. It keeps the one place
/// that reads session state down to a handful of lines, and it is the only
/// reason the screen can be put in a preview at all: Ferrostar's
/// `NavigationState` has an internal initialiser, so a state cannot be built
/// outside its own module.
struct NavigationSnapshot {
    var instruction: VisualInstruction?
    var progress: TripProgress?
    /// Qualified because MapKit's SwiftUI layer has a `UserLocation` too.
    var userLocation: FerrostarCoreFFI.UserLocation?
    var remainingGeometry: [CLLocationCoordinate2D] = []
    var motionGeometry: [CLLocationCoordinate2D] = []
    var isOnRoute = true
    var destinationName: String = "Destination"
    var destinationCoordinate: CLLocationCoordinate2D?
    var cameras: [SurveillanceCamera] = []
    var status: NavigationStatus = .quiet
    var isMuted: Bool = false
    var voiceEnabled: Bool = true
}

/// Turn-by-turn guidance, live.
///
/// Shadows SwiftUI's long-deprecated `NavigationView`, which nothing in this
/// app uses; every screen here is built on `NavigationStack`.
///
/// Rendered as an overlay inside the Route tab, not a sheet and not a
/// `fullScreenCover`. The proximity warning is drawn above the tab view in
/// `ContentView`, and a modal presentation would cover it. A camera warning
/// has to stay visible while navigating: that is what the app is for.
///
/// This is the only type that reads `NavigationSessionController`, and it
/// reads it and nothing else. No position is computed here, nothing is snapped
/// to a road, nothing is spoken and nothing is fetched.
struct NavigationView: View {

    @Environment(NavigationSessionController.self) private var navigationController
    @Environment(ProximityAlertEngine.self) private var proximityEngine
    @AppStorage(VoiceSettings.masterKey) private var voiceEnabled = true

    /// The cameras the previewed route was planned against. The controller
    /// keeps its own copy to fence reroutes against but does not publish it,
    /// so the route planner hands them down for drawing.
    let cameras: [SurveillanceCamera]

    /// How long the result of a reroute stays on screen.
    private static let rerouteToastSeconds: Double = 6

    @State private var showsRerouteToast = false

    var body: some View {
        ZStack {
            if navigationController.isActive {
                NavigationDrivingView(
                    snapshot: snapshot,
                    proximityBannerShowing: proximityEngine.activeAlert != nil,
                    onToggleMute: { navigationController.toggleMute() },
                    onEnd: { navigationController.stop() }
                )
                .transition(.opacity)
            }

            if let summary = navigationController.tripSummary {
                summaryLayer(summary)
            }
        }
        .animation(.easeOut(duration: 0.25), value: navigationController.isActive)
        .animation(.easeOut(duration: 0.25), value: navigationController.tripSummary != nil)
        .task(id: navigationController.lastReroute?.date) {
            // Only reroutes land here: `start` clears `lastReroute`, and the
            // first route is issued directly rather than through the provider
            // that reports plans.
            guard navigationController.lastReroute != nil else { return }
            showsRerouteToast = true
            try? await Task.sleep(for: .seconds(Self.rerouteToastSeconds))
            guard !Task.isCancelled else { return }
            showsRerouteToast = false
        }
    }

    // MARK: - Session State

    private var snapshot: NavigationSnapshot {
        let state = navigationController.state
        return NavigationSnapshot(
            instruction: state?.currentVisualInstruction,
            progress: state?.currentProgress,
            userLocation: state?.preferredUserLocation,
            remainingGeometry: remainingGeometry,
            motionGeometry: motionGeometry,
            isOnRoute: state?.currentDeviation == .noDeviation,
            destinationName: navigationController.destination?.name ?? "Destination",
            destinationCoordinate: navigationController.destination?.coordinate,
            cameras: cameras,
            status: status,
            isMuted: navigationController.isMuted,
            voiceEnabled: voiceEnabled
        )
    }

    /// The part of the route still ahead.
    ///
    /// Ferrostar already splits the route into steps and says which are left,
    /// so this is a concatenation of what it reports rather than anything this
    /// view works out. Until the first fix arrives there are no remaining
    /// steps, and the whole route stands in.
    private var remainingGeometry: [CLLocationCoordinate2D] {
        if let steps = navigationController.state?.remainingSteps, !steps.isEmpty {
            return steps.flatMap(\.geometry).map(\.clLocationCoordinate2D)
        }
        return navigationController.currentRoute?.geometry.map(\.clLocationCoordinate2D) ?? []
    }

    private var motionGeometry: [CLLocationCoordinate2D] {
        guard let route = navigationController.currentRoute, let remaining = navigationController.state?.remainingSteps else { return [] }
        let current = max(0, route.steps.count - remaining.count)
        // Include the just-completed step for the presentation buffer without
        // letting an earlier crossing of a looping route win projection.
        return route.steps[max(0, current - 1)..<min(route.steps.count, current + 2)]
            .flatMap(\.geometry).map(\.clLocationCoordinate2D)
    }

    private var status: NavigationStatus {
        if navigationController.isRerouting || navigationController.state?.isCalculatingNewRoute == true {
            return .rerouting
        }
        if navigationController.rerouteFailed {
            return .rerouteFailed
        }
        if showsRerouteToast, let reroute = navigationController.lastReroute {
            return .rerouted(avoided: reroute.avoidedCount, total: reroute.totalCount)
        }
        return .quiet
    }

    /// Arrival tears the session down as soon as it has the numbers, so the
    /// card outlives `isActive` and the route planner's own map is what shows
    /// behind it.
    private func summaryLayer(_ summary: NavigationSessionController.TripSummary) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            TripSummaryView(summary: summary) {
                navigationController.dismissSummary()
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Driving Screen

/// The map, the turn card and the controls.
///
/// Split from `NavigationView` so that the drawing takes values rather than a
/// live session: it is what makes the screen previewable.
struct NavigationDrivingView: View {

    let snapshot: NavigationSnapshot
    var proximityBannerShowing: Bool = false
    let onToggleMute: () -> Void
    let onEnd: () -> Void

    @AppStorage(DistanceUnits.storageKey) private var useMetric: Bool = false

    @State private var isFollowing = true

    /// The proximity banner's height plus its own top padding and a gap.
    /// `ContentView` draws that banner above the tab view, and issue #15 asks
    /// for both banners visible at once rather than one on top of the other.
    private static let proximityReserve: CGFloat = 76

    private var format: NavigationFormat { NavigationFormat(useMetric: useMetric) }

    var body: some View {
        map
            .safeAreaInset(edge: .top, spacing: 0) { topChrome }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
    }

    // MARK: - Map

    private var map: some View {
        NavigationMotionMap(snapshot: snapshot, following: $isFollowing)
    }

    // MARK: - Chrome

    private var topChrome: some View {
        VStack(spacing: 10) {
            NavigationBannerView(
                instruction: snapshot.instruction,
                distanceToNextManeuver: snapshot.progress?.distanceToNextManeuver,
                fallbackTitle: snapshot.destinationName
            )
            NavigationStatusView(status: snapshot.status)
        }
        .padding(.horizontal, 16)
        .padding(.top, proximityBannerShowing ? Self.proximityReserve : 8)
        .animation(.easeOut(duration: 0.25), value: proximityBannerShowing)
        .animation(.easeOut(duration: 0.25), value: snapshot.status)
    }

    private var bottomChrome: some View {
        VStack(spacing: 10) {
            if !isFollowing {
                recenterButton
            }
            progressBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.2), value: isFollowing)
    }

    private var recenterButton: some View {
        Button {
            isFollowing = true
        } label: {
            Label("Re-center", systemImage: "location.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.thickMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("navigation-recenter")
    }

    private var progressBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryProgressText)
                    .font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText())
                Text(secondaryProgressText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            muteButton
            endButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: snapshot.isMuted || !snapshot.voiceEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.title3)
                .foregroundStyle(snapshot.isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(NavigationPalette.accent))
                .frame(width: 46, height: 46)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!snapshot.voiceEnabled)
        .accessibilityLabel(!snapshot.voiceEnabled ? "Voice off in Settings" : snapshot.isMuted ? "Unmute trip speech" : "Mute trip speech")
        .accessibilityIdentifier("navigation-mute")
    }

    private var endButton: some View {
        Button(action: onEnd) {
            Text("End")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 46)
                .background(.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("navigation-end")
    }

    // MARK: - Progress Text

    private var primaryProgressText: String {
        guard let progress = snapshot.progress else { return "\u{2014}" }
        return format.duration(progress.durationRemaining)
    }

    private var secondaryProgressText: String {
        guard let progress = snapshot.progress else { return "Starting\u{2026}" }
        let distance = format.distance(progress.distanceRemaining)
        let arrival = format.arrival(in: progress.durationRemaining)
        return "\(distance) \u{00B7} arrives \(arrival)"
    }
}

// MARK: - Previews

/// Preview fixtures sit on the null island in 0.001 steps, so nothing here
/// names a place.
private enum NavigationPreview {

    static let geometry: [CLLocationCoordinate2D] = (0...12).map { step in
        CLLocationCoordinate2D(latitude: Double(step) * 0.001, longitude: Double(step) * 0.0005)
    }

    static var userLocation: FerrostarCoreFFI.UserLocation {
        FerrostarCoreFFI.UserLocation(
            coordinates: GeographicCoordinate(lat: 0.002, lng: 0.001),
            horizontalAccuracy: 8,
            courseOverGround: CourseOverGround(degrees: 26, accuracy: 6),
            timestamp: Date(),
            speed: Speed(value: 14, accuracy: 2)
        )
    }

    static let progress = TripProgress(
        distanceToNextManeuver: 240,
        distanceRemaining: 18_400,
        durationRemaining: 22 * 60,
        durationToNextManeuver: 40
    )

    static func instruction(
        text: String,
        type: FerrostarCoreFFI.ManeuverType,
        modifier: FerrostarCoreFFI.ManeuverModifier?
    ) -> VisualInstruction {
        VisualInstruction(
            primaryContent: VisualInstructionContent(
                text: text,
                maneuverType: type,
                maneuverModifier: modifier,
                roundaboutExitDegrees: nil,
                laneInfo: nil,
                exitNumbers: []
            ),
            secondaryContent: nil,
            subContent: nil,
            triggerDistanceBeforeManeuver: 300
        )
    }

    static let cameras: [SurveillanceCamera] = [
        SurveillanceCamera(
            osmID: 1,
            latitude: 0.004,
            longitude: 0.002,
            tags: ["surveillance:type": "ALPR", "direction": "30"]
        ),
        SurveillanceCamera(
            osmID: 2,
            latitude: 0.007,
            longitude: 0.0035,
            tags: ["surveillance:type": "speed_camera"]
        ),
    ]

    static var snapshot: NavigationSnapshot {
        NavigationSnapshot(
            instruction: instruction(
                text: "Turn right onto Example Avenue",
                type: .turn,
                modifier: .right
            ),
            progress: progress,
            userLocation: userLocation,
            remainingGeometry: geometry,
            destinationName: "Test Destination",
            destinationCoordinate: geometry.last,
            cameras: cameras,
            status: .quiet,
            isMuted: false
        )
    }
}

#Preview("Navigating") {
    NavigationDrivingView(
        snapshot: NavigationPreview.snapshot,
        onToggleMute: {},
        onEnd: {}
    )
}

#Preview("Rerouting, Muted, With A Warning") {
    var snapshot = NavigationPreview.snapshot
    snapshot.status = .rerouting
    snapshot.isMuted = true

    return NavigationDrivingView(
        snapshot: snapshot,
        proximityBannerShowing: true,
        onToggleMute: {},
        onEnd: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Reroute Result") {
    var snapshot = NavigationPreview.snapshot
    snapshot.status = .rerouted(avoided: 4, total: 6)
    snapshot.instruction = NavigationPreview.instruction(
        text: "Keep left",
        type: .fork,
        modifier: .left
    )

    return NavigationDrivingView(
        snapshot: snapshot,
        onToggleMute: {},
        onEnd: {}
    )
}
