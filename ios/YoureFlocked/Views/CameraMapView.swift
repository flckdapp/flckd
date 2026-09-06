import SwiftUI
import MapKit
import SwiftData
import UIKit

// MARK: - Map Rotation Model

/// Holds the live map heading for FOV-cone counter-rotation.
/// Kept as a separate @Observable object (not view @State) so per-frame
/// heading updates during map rotation invalidate only the marker views
/// that read it, not the full map content builder.
@Observable @MainActor
final class MapRotationModel {
    var heading: Double = 0
}

// MARK: - Camera Map View

/// Main map screen showing surveillance cameras as markers.
/// Fetches cameras from Overpass API as the user pans/zooms,
/// and runs proximity checks on each location update.
struct CameraMapView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(CameraStore.self) private var cameraStore
    @Environment(NotificationManager.self) private var notificationManager
    @Environment(LiveActivityManager.self) private var liveActivityManager
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel = MapViewModel()
    @State private var rotationModel = MapRotationModel()
    @State private var suspectedLocations: [SuspectedLocation] = []
    @State private var isLoadingSuspectedLocations: Bool = false
    @State private var isDownloadingArea: Bool = false
    @State private var showDownloadAlert: Bool = false
    @State private var downloadAlertMessage: String = ""
    @AppStorage("alertMode") private var alertModeRaw: String = AlertMode.nearCamera.rawValue
    @AppStorage("showDebugOverlay") private var showDebugOverlay: Bool = false
    @AppStorage("offlineRadius") private var offlineRadius: Double = 20.0
    @State private var selectedMapStyle: MapStyleOption = .standard
    @State private var showMapStylePicker: Bool = false
    @AppStorage("showSuspectedLocations") private var showSuspectedLocations: Bool = false
    @AppStorage("enableHaptics") private var enableHaptics: Bool = true

    var body: some View {
        ZStack {
            mapContent
            proximityBanner
            fetchStatusBanner
            overlayControls
            if showDebugOverlay { debugOverlay }
        }
        .sheet(isPresented: $viewModel.showCameraDetail) {
            if let camera = viewModel.selectedCamera {
                CameraDetailView(camera: camera)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showMapStylePicker) {
            MapStyleSheet(selectedStyle: $selectedMapStyle, currentRegion: viewModel.visibleRegion)
                .presentationDetents([.height(280)])
                .presentationBackgroundInteraction(.enabled)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(24)
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $viewModel.showTripSummary, onDismiss: { viewModel.resetTrip() }) {
            TripSummarySheet(stats: viewModel.tripStats) {
                viewModel.resetTrip()
                viewModel.showTripSummary = false
            }
            .presentationDetents([.height(280)])
            .presentationBackgroundInteraction(.enabled)
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(24)
            .presentationDragIndicator(.hidden)
        }
        .onChange(of: viewModel.followMode) { _, _ in
            viewModel.checkTripEnd()
        }
        .alert("Offline Download", isPresented: $showDownloadAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadAlertMessage)
        }
        .onAppear {
            locationManager.startHeading()
        }
        .onDisappear {
            locationManager.stopHeading()
        }
        .task {
            _ = await notificationManager.requestAuthorization()
            await cameraStore.loadFromCache(container: modelContext.container)
            // Write-through: successful fetches persist automatically so the
            // next launch has cameras even if Overpass is down.
            cameraStore.cacheContainer = modelContext.container
            await loadSuspectedLocations()
        }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            guard let location = newLocation else { return }
            viewModel.handleLocationUpdate(
                location: location,
                heading: locationManager.heading,
                cameraStore: cameraStore,
                notificationManager: notificationManager,
                liveActivityManager: liveActivityManager,
                alertRadius: locationManager.alertRadius,
                alertMode: AlertMode(rawValue: alertModeRaw) ?? .nearCamera,
                enableHaptics: enableHaptics
            )
        }
    }

    // MARK: - Proximity Banner Overlay

    @ViewBuilder
    private var proximityBanner: some View {
        VStack {
            if let alert = viewModel.activeAlert {
                ProximityBannerView(alert: alert, tripStats: viewModel.tripStats)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
                    .padding(.top, 8)
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.activeAlert != nil)
    }

    // MARK: - Fetch Status Banner

    /// Small capsule shown when the camera-data fetch failed, so an
    /// Overpass outage is distinguishable from "no cameras in this area".
    @ViewBuilder
    private var fetchStatusBanner: some View {
        VStack {
            if cameraStore.lastError != nil, viewModel.activeAlert == nil {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                    Text("Camera data unavailable — retrying")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.25), value: cameraStore.lastError == nil)
        .allowsHitTesting(false)
    }

    // MARK: - Map Content

    @ViewBuilder
    private var mapContent: some View {
        Map(position: $viewModel.cameraPosition) {
            UserAnnotation()

            // Camera markers: individual cameras up to the cluster
            // threshold, numbered roll-up badges beyond it.
            let content = viewModel.annotationContent(from: cameraStore.cameras)
            ForEach(content.cameras) { camera in
                Annotation(camera.displayName, coordinate: camera.coordinate) {
                    CameraMarkerView(
                        camera: camera,
                        rotation: rotationModel,
                        isPending: cameraStore.isPending(camera)
                    )
                    .onTapGesture {
                        viewModel.selectCamera(camera)
                    }
                }
            }
            ForEach(content.clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate) {
                    ClusterBadgeView(count: cluster.count)
                        .onTapGesture {
                            viewModel.zoomTo(cluster)
                        }
                }
            }

            if showSuspectedLocations {
                let visibleSuspected = visibleSuspectedLocations(in: viewModel.visibleRegion)
                ForEach(visibleSuspected) { location in
                    Annotation("Suspected ALPR", coordinate: location.coordinate) {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 10, height: 10)
                            .overlay {
                                Circle()
                                    .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                            }
                    }
                }
            }
        }
        .mapStyle(selectedMapStyle.style)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            // Only feed the lightweight rotation model here. Writing view
            // @State or the view model per frame re-renders the entire map
            // body (re-filtering and re-diffing every annotation) on every
            // frame of a heading-follow rotation, which starves MapKit's own
            // animation.
            rotationModel.heading = context.camera.heading
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            rotationModel.heading = context.camera.heading
            viewModel.visibleRegion = context.region
            Task {
                await viewModel.onRegionChange(
                    region: context.region,
                    cameraStore: cameraStore,
                    currentLocation: locationManager.currentLocation
                )
            }
        }
    }

    // MARK: - Overlay Controls

    @ViewBuilder
    private var overlayControls: some View {
        VStack {
            HStack {
                Spacer()

                VStack(spacing: 0) {
                    Button {
                        lightHaptic()
                        showMapStylePicker.toggle()
                    } label: {
                        Image(systemName: mapStyleIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .background(Color.primary.opacity(0.18))
                        .padding(.horizontal, 10)

                    Button {
                        lightHaptic()
                        viewModel.cycleFollowMode()
                    } label: {
                        Image(systemName: followModeIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(viewModel.followMode == .off ? .primary : .blue)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 44, height: 88)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
            }
            .padding(.top, 80)
            .padding(.trailing, 12)

            Spacer()

            if !cameraStore.cameras.isEmpty || cameraStore.isLoading {
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        if cameraStore.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        if !cameraStore.cameras.isEmpty {
                            Text("\(cameraStore.cameras.count)\(cameraStore.isAtStoreCap ? "+" : "")")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
                .padding(.trailing, 12)
                .padding(.bottom, 20)
            }
        }
    }

    private var followModeIcon: String {
        switch viewModel.followMode {
        case .off: return "location"
        case .follow: return "location.fill"
        case .followHeading: return "location.north.line.fill"
        }
    }

    private var mapStyleIcon: String {
        switch selectedMapStyle {
        case .standard: return "map"
        case .satellite: return "globe.americas"
        case .hybrid: return "map.fill"
        }
    }
    
    private func lightHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    // MARK: - Debug Overlay

    @ViewBuilder
    private var debugOverlay: some View {
        VStack {
            let authText: String = switch locationManager.authorizationStatus {
            case .notDetermined: "NOT DETERMINED"
            case .denied: "DENIED"
            case .restricted: "RESTRICTED"
            case .authorizedWhenInUse: "WHEN IN USE"
            case .authorizedAlways: "ALWAYS"
            @unknown default: "UNKNOWN"
            }
            let locText: String = if let loc = locationManager.currentLocation {
                String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude)
            } else {
                "nil"
            }
            Text("Auth: \(authText) | Tracking: \(locationManager.isTracking) | Loc: \(locText)")
                .font(.caption2.monospaced())
                .padding(6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.top, 4)
            Spacer()
        }
    }

    @MainActor
    private func loadSuspectedLocations() async {
        guard !isLoadingSuspectedLocations else { return }
        isLoadingSuspectedLocations = true
        defer { isLoadingSuspectedLocations = false }

        do {
            suspectedLocations = try await SuspectedLocationService.shared.loadSuspectedLocations()
        } catch {
            suspectedLocations = []
        }
    }

    private func visibleSuspectedLocations(in region: MKCoordinateRegion?) -> [SuspectedLocation] {
        guard let region else { return [] }

        let latMin = region.center.latitude - (region.span.latitudeDelta / 2)
        let latMax = region.center.latitude + (region.span.latitudeDelta / 2)
        let lonMin = region.center.longitude - (region.span.longitudeDelta / 2)
        let lonMax = region.center.longitude + (region.span.longitudeDelta / 2)

        return suspectedLocations.filter { location in
            location.latitude >= latMin &&
            location.latitude <= latMax &&
            location.longitude >= lonMin &&
            location.longitude <= lonMax
        }
    }

    @MainActor
    private func downloadVisibleArea() async {
        guard !isDownloadingArea else { return }
        guard let region = viewModel.visibleRegion else {
            downloadAlertMessage = "Move the map first, then try Download Area again."
            showDownloadAlert = true
            return
        }

        isDownloadingArea = true
        defer { isDownloadingArea = false }

        do {
            let count = try await cameraStore.downloadArea(
                around: region.center,
                radiusKm: offlineRadius,
                context: modelContext
            )
            downloadAlertMessage = "Saved \(count) cameras for offline use in this area."
            showDownloadAlert = true
        } catch {
            downloadAlertMessage = "Download failed: \(error.localizedDescription)"
            showDownloadAlert = true
        }
    }
}

// MARK: - Map Style Sheet

struct MapStyleSheet: View {
    @Binding var selectedStyle: MapStyleOption
    let currentRegion: MKCoordinateRegion?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Map Modes")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            HStack(spacing: 12) {
                ForEach(MapStyleOption.allCases) { style in
                    MapSnapshotButton(
                        style: style,
                        isSelected: selectedStyle == style,
                        region: currentRegion
                    ) {
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                        selectedStyle = style
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
    }
}

struct MapSnapshotButton: View {
    let style: MapStyleOption
    let isSelected: Bool
    let region: MKCoordinateRegion?
    let action: () -> Void
    
    @State private var snapshotImage: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Rectangle()
                        .fill(placeholderGradient)
                    
                    if let image = snapshotImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    }
                    
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2.5 : 1)
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                
                Text(style.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .task {
            await generateSnapshot()
        }
    }
    
    private var placeholderGradient: LinearGradient {
        switch style {
        case .standard:
            return LinearGradient(colors: [.gray.opacity(0.2), .green.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .satellite:
             return LinearGradient(colors: [.black.opacity(0.8), .green.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .hybrid:
             return LinearGradient(colors: [.black.opacity(0.8), .gray.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    
    @MainActor
    private func generateSnapshot() async {
        guard let region = region, snapshotImage == nil else { return }
        
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 80, height: 80)
        options.scale = UIScreen.main.scale
        
        switch style {
        case .standard: options.mapType = .standard
        case .satellite: options.mapType = .satellite
        case .hybrid: options.mapType = .hybrid
        }
        
        let snapshotter = MKMapSnapshotter(options: options)
        
        do {
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                snapshotter.start { snapshot, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let snapshot {
                        continuation.resume(returning: snapshot.image)
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
            }
            self.snapshotImage = image
        } catch {
            print("Snapshot failed: \(error)")
        }
    }
}

// MARK: - Trip Summary Sheet

struct TripSummarySheet: View {
    let stats: MapViewModel.TripStats
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Trip Summary")
                    .font(.title3.bold())
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.quaternary)
                        .clipShape(Circle())
                }
            }

            HStack(spacing: 24) {
                statBubble(
                    count: stats.totalCount,
                    label: "Total",
                    color: .primary
                )
                if stats.alprCount > 0 {
                    statBubble(
                        count: stats.alprCount,
                        label: "ALPR",
                        color: .red
                    )
                }
                if stats.speedCount > 0 {
                    statBubble(
                        count: stats.speedCount,
                        label: "Speed",
                        color: .yellow
                    )
                }
                if stats.otherCount > 0 {
                    statBubble(
                        count: stats.otherCount,
                        label: "Other",
                        color: .orange
                    )
                }
            }

            Text("Camera\(stats.totalCount == 1 ? "" : "s") encountered during this trip")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(20)
    }

    private func statBubble(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Map Style Option

enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard
    case satellite
    case hybrid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas"
        case .hybrid: return "map.fill"
        }
    }

    var style: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .realistic)
        case .satellite: return .imagery(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic)
        }
    }
}

// MARK: - Camera Marker View

struct CameraMarkerView: View {
    let camera: SurveillanceCamera
    /// Live map heading source. Only this small view observes it, so
    /// continuous rotation never re-renders the whole map hierarchy.
    var rotation: MapRotationModel? = nil
    var isPending: Bool = false
    private let coneRadius: CGFloat = 44

    var body: some View {
        ZStack {
            ForEach(camera.directions.indices, id: \.self) { i in
                let entry = camera.directions[i]
                FieldOfViewCone(halfAngle: entry.halfAngle)
                    .fill(
                        RadialGradient(
                            colors: [
                                markerColor.opacity(0.5),
                                markerColor.opacity(0.1),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: coneRadius
                        )
                    )
                    .overlay(
                        FieldOfViewCone(halfAngle: entry.halfAngle)
                            .strokeBorder(markerColor.opacity(0.3), lineWidth: 1)
                    )
                    .frame(width: coneRadius * 2, height: coneRadius * 2)
                    .rotationEffect(.degrees(entry.center - (rotation?.heading ?? 0)))
                    .allowsHitTesting(false)
            }

            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                if isPending {
                    Circle()
                        .strokeBorder(markerColor, style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
                        .frame(width: 14, height: 14)
                } else {
                    Circle()
                        .fill(markerColor)
                        .frame(width: 14, height: 14)
                }
            }
        }
    }

    private var markerColor: Color {
        switch camera.surveillanceType {
        case .alpr: return .red
        case .camera: return .orange
        case .speedCamera: return .yellow
        case .gunshotDetector: return .purple
        default: return .gray
        }
    }
}

// MARK: - Field of View Cone Shape

struct FieldOfViewCone: InsettableShape {
    let halfAngle: Double
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) / 2) - insetAmount

        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90 - halfAngle),
            endAngle: .degrees(-90 + halfAngle),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
    
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

#Preview {
    NavigationStack {
        CameraMapView()
            .environment(LocationManager())
            .environment(CameraStore())
            .environment(NotificationManager())
            .environment(LiveActivityManager())
    }
}


// MARK: - Cluster Badge

/// Numbered roll-up badge shown when too many cameras are in view to
/// render individually. Tapping zooms in far enough to break it apart.
private struct ClusterBadgeView: View {
    let count: Int

    private var label: String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Circle().fill(Color.red.opacity(0.88)).aspectRatio(1, contentMode: .fill))
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .accessibilityLabel("\(count) cameras, tap to zoom in")
    }
}
