import Foundation
import SwiftUI
import MapKit
import CoreLocation
import UIKit

// MARK: - Relative Direction

/// Bucketed direction from the user toward a camera, relative to user's heading.
enum RelativeDirection: String, CaseIterable {
    case ahead = "Ahead"
    case right = "Right"
    case behind = "Behind"
    case left = "Left"
    case nearby = "Nearby" // Heading unavailable

    /// Classify a relative bearing (0–360, where 0 = directly ahead) into a direction bucket.
    static func from(relativeBearing: Double) -> RelativeDirection {
        let angle = relativeBearing.truncatingRemainder(dividingBy: 360)
        let normalized = angle < 0 ? angle + 360 : angle

        switch normalized {
        case 0..<45, 315..<360:
            return .ahead
        case 45..<135:
            return .right
        case 135..<225:
            return .behind
        case 225..<315:
            return .left
        default:
            return .nearby
        }
    }

    /// Rotation angle for a direction arrow icon (degrees, clockwise from up).
    var arrowRotation: Double {
        switch self {
        case .ahead: return 0
        case .right: return 90
        case .behind: return 180
        case .left: return 270
        case .nearby: return 0
        }
    }
}

// MARK: - Map View Model

/// Drives the main map view: camera position, visible region, fetch triggers,
/// and proximity alert coordination with hysteresis and cooldown.
@Observable @MainActor
final class MapViewModel {

    // MARK: - Map State

    var cameraPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    var visibleRegion: MKCoordinateRegion?
    var selectedCamera: SurveillanceCamera?
    var showCameraDetail: Bool = false
    var hasInitialLocation: Bool = false
    var mapHeading: Double = 0

    enum FollowMode: String {
        case off
        case follow          // north-up, centers on user
        case followHeading   // rotates map to heading, like Apple Maps driving
    }

    var followMode: FollowMode {
        if cameraPosition.followsUserHeading { return .followHeading }
        if cameraPosition == .userLocation(fallback: .automatic) { return .follow }
        return .off
    }

    var isFollowingUser: Bool { followMode != .off }

    // MARK: - Filter State

    var showALPROnly: Bool = false
    var showSpeedCameras: Bool = true
    var showGenericCameras: Bool = true

    // MARK: - Trip Encounter Tracking

    struct TripStats {
        var alprCount: Int = 0
        var speedCount: Int = 0
        var otherCount: Int = 0
        var encounteredCameraIDs: Set<Int64> = []

        var totalCount: Int { alprCount + speedCount + otherCount }
        var isEmpty: Bool { totalCount == 0 }

        var summary: String {
            var parts: [String] = []
            if alprCount > 0 { parts.append("\(alprCount) ALPR") }
            if speedCount > 0 { parts.append("\(speedCount) speed") }
            if otherCount > 0 { parts.append("\(otherCount) other") }
            return parts.isEmpty ? "No cameras" : parts.joined(separator: ", ")
        }
    }

    var tripStats = TripStats()
    var showTripSummary: Bool = false
    private var tripWasActive: Bool = false

    func recordEncounter(camera: SurveillanceCamera) {
        guard !tripStats.encounteredCameraIDs.contains(camera.osmID) else { return }
        tripStats.encounteredCameraIDs.insert(camera.osmID)

        switch camera.surveillanceType {
        case .alpr: tripStats.alprCount += 1
        case .speedCamera: tripStats.speedCount += 1
        default: tripStats.otherCount += 1
        }
    }

    func checkTripEnd() {
        if tripWasActive && !isFollowingUser {
            if !tripStats.isEmpty {
                showTripSummary = true
            }
            tripWasActive = false
        } else if isFollowingUser {
            tripWasActive = true
        }
    }

    func resetTrip() {
        tripStats = TripStats()
        showTripSummary = false
    }

    // MARK: - Proximity Alert State

    /// The currently displayed proximity alert (drives the banner).
    /// When non-nil, the banner is visible.
    var activeAlert: ProximityAlert?

    /// Rich proximity alert model for the non-modal banner.
    struct ProximityAlert: Equatable {
        let cameraID: Int64
        let camera: SurveillanceCamera
        var distance: CLLocationDistance
        var bearing: Double                     // Absolute compass bearing from user to camera
        var relativeBearing: Double?            // Relative to user heading (nil = heading unavailable)
        var relativeDirection: RelativeDirection
        var nearbyCount: Int                    // Other cameras also within radius
        let enteredAt: Date                     // When user first entered this camera's radius
        var hasTriggeredVeryClose: Bool          // One-shot: triggered "very close" haptic

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.cameraID == rhs.cameraID
        }
    }

    // MARK: - Proximity State Machine

    /// Hysteresis: exit radius is 20% larger than enter radius to prevent flicker at boundary.
    private let exitRadiusMultiplier: Double = 1.2

    /// Grace period (seconds) after exiting radius before dismissing the banner.
    private let exitGraceDuration: TimeInterval = 8.0

    /// Per-camera cooldown: don't re-trigger haptics within this window.
    private let cameraCooldownDuration: TimeInterval = 60.0

    /// Distance threshold for "very close" escalation haptic.
    private let veryCloseRadius: CLLocationDistance = 60

    /// Minimum speed (m/s) to suppress haptics when stationary (e.g., parked).
    private let stationarySpeedThreshold: CLLocationSpeed = 3.0

    /// Exit grace timer, cancelled if the user re-enters the radius.
    private var exitGraceTask: Task<Void, Never>?

    /// Per-camera cooldown timestamps (cameraID → last entry time).
    private var cameraCooldowns: [Int64: Date] = [:]

    /// Whether we are in exit-grace (camera left radius, waiting before dismiss).
    private var isInExitGrace: Bool = false

    // MARK: - Computed

    /// Cameras filtered by current filter settings
    func filteredCameras(from allCameras: [SurveillanceCamera]) -> [SurveillanceCamera] {
        allCameras.filter { camera in
            switch camera.surveillanceType {
            case .alpr:
                return true // ALPRs are always shown.
            case .speedCamera:
                return showSpeedCameras
            case .camera:
                return showGenericCameras
            default:
                return !showALPROnly
            }
        }
    }

    /// A rolled-up group of nearby cameras, shown as a numbered badge
    /// when too many individual markers would be on screen at once.
    struct CameraCluster: Identifiable, Equatable {
        let id: String
        let latitude: Double
        let longitude: Double
        let count: Int
        let spanLat: Double
        let spanLon: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// What the map should draw: individual cameras, clusters, or a mix.
    struct MapAnnotationContent {
        var cameras: [SurveillanceCamera] = []
        var clusters: [CameraCluster] = []
    }

    /// Above this many in-view markers the map rolls cameras up into
    /// numbered cluster blocks. Rendering thousands of individual
    /// Annotation views makes the map unresponsive and slows cold launch.
    private let clusterThreshold = 600

    /// Cameras/clusters that should actually be rendered: filtered, culled
    /// to the visible region (with margin), and clustered past the threshold.
    func annotationContent(from allCameras: [SurveillanceCamera]) -> MapAnnotationContent {
        let filtered = filteredCameras(from: allCameras)
        guard let region = visibleRegion else {
            return MapAnnotationContent(cameras: Array(filtered.prefix(clusterThreshold)))
        }
        // 30% margin so markers don't pop in right at the screen edge.
        let padLat = region.span.latitudeDelta * 0.65
        let padLon = region.span.longitudeDelta * 0.65
        let center = region.center
        let inView = filtered.filter {
            abs($0.latitude - center.latitude) <= padLat &&
            abs($0.longitude - center.longitude) <= padLon
        }
        if inView.count <= clusterThreshold {
            return MapAnnotationContent(cameras: inView)
        }

        // Grid-cluster the padded viewport (~9x14 cells). Each non-empty
        // cell becomes one badge at the centroid of its cameras.
        let cols = 9.0
        let rows = 14.0
        let cellLon = max((padLon * 2) / cols, 1e-6)
        let cellLat = max((padLat * 2) / rows, 1e-6)
        let minLat = center.latitude - padLat
        let minLon = center.longitude - padLon

        var buckets: [Int: (latSum: Double, lonSum: Double, count: Int)] = [:]
        for camera in inView {
            let col = Int((camera.longitude - minLon) / cellLon)
            let row = Int((camera.latitude - minLat) / cellLat)
            let key = row &* 10_000 &+ col
            var bucket = buckets[key] ?? (0, 0, 0)
            bucket.latSum += camera.latitude
            bucket.lonSum += camera.longitude
            bucket.count += 1
            buckets[key] = bucket
        }

        let clusters = buckets.map { key, bucket in
            CameraCluster(
                id: "cluster-\(key)",
                latitude: bucket.latSum / Double(bucket.count),
                longitude: bucket.lonSum / Double(bucket.count),
                count: bucket.count,
                spanLat: cellLat * 2.5,
                spanLon: cellLon * 2.5
            )
        }
        return MapAnnotationContent(clusters: clusters)
    }

    /// Tap on a cluster badge: zoom in far enough to break it apart.
    func zoomTo(_ cluster: CameraCluster) {
        withAnimation(.smooth(duration: 0.45)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: cluster.coordinate,
                    span: MKCoordinateSpan(
                        latitudeDelta: cluster.spanLat,
                        longitudeDelta: cluster.spanLon
                    )
                )
            )
        }
    }

    // MARK: - Region-based Fetching

    /// Called when the visible map region changes. Determines if we need to fetch new data.
    func onRegionChange(
        region: MKCoordinateRegion,
        cameraStore: CameraStore,
        currentLocation: CLLocation?
    ) async {
        visibleRegion = region

        // Use map center as fetch point (user may be panning)
        let center = region.center

        // Scale the fetch radius with the visible span so a zoomed-out view
        // covers what the user sees, clamped to 40 km to keep Overpass
        // queries reasonable.
        let latKm = region.span.latitudeDelta * 111.0
        let lonKm = region.span.longitudeDelta * 111.0 * cos(center.latitude * .pi / 180)
        let radiusKm = min(max(max(latKm, lonKm) * 0.6, cameraStore.fetchRadiusKm), 40)
        await cameraStore.fetchCameras(around: center, radiusKm: radiusKm)
    }

    // MARK: - Location Tracking

    func cycleFollowMode() {
        withAnimation(.smooth(duration: 0.5)) {
            switch followMode {
            case .off:
                cameraPosition = .userLocation(fallback: .automatic)
            case .follow:
                cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            case .followHeading:
                // Keep the current view when leaving follow mode. `.automatic`
                // frames every annotation, which zooms far out after a long
                // pan session.
                if let region = visibleRegion {
                    cameraPosition = .region(region)
                } else {
                    cameraPosition = .automatic
                }
            }
        }
    }

    // MARK: - Proximity Alert Handling

    /// Main proximity update, called on every location change.
    /// Implements hysteresis, per-camera cooldown, haptic triggers, and banner state.
    func handleLocationUpdate(
        location: CLLocation,
        heading: CLHeading?,
        cameraStore: CameraStore,
        notificationManager: NotificationManager,
        liveActivityManager: LiveActivityManager?,
        alertRadius: CLLocationDistance,
        alertMode: AlertMode,
        enableHaptics: Bool
    ) {
        // Initial fetch on first location
        if !hasInitialLocation {
            hasInitialLocation = true
            Task { await cameraStore.fetchCameras(around: location.coordinate) }
        }

        let nearby = cameraStore.checkProximity(
            location: location,
            alertRadius: alertRadius,
            alertMode: alertMode
        )

        let exitRadius = alertRadius * exitRadiusMultiplier
        let compassHeading = heading?.trueHeading
        let userHeading: Double? = if let h = compassHeading, h >= 0 {
            h
        } else if location.course >= 0 {
            location.course
        } else {
            nil
        }

        // Check cameras within exit radius for hysteresis.
        // Bounding-box prefilter first: a full CLLocation/haversine pass
        // over thousands of stored cameras on every location update is
        // measurable main-thread work.
        let exitLatWindow = exitRadius * 1.5 / 111_000.0
        let exitLonWindow = exitLatWindow / max(0.2, cos(location.coordinate.latitude * .pi / 180))
        let withinExitRadius = cameraStore.cameras.compactMap { camera -> (camera: SurveillanceCamera, distance: CLLocationDistance)? in
            guard abs(camera.latitude - location.coordinate.latitude) <= exitLatWindow,
                  abs(camera.longitude - location.coordinate.longitude) <= exitLonWindow else { return nil }
            let cameraLocation = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
            let distance = location.distance(from: cameraLocation)
            guard distance <= exitRadius else { return nil }

            if alertMode == .inFieldOfView {
                guard camera.isInFieldOfView(from: location.coordinate) else { return nil }
            }

            return (camera: camera, distance: distance)
        }.sorted { $0.distance < $1.distance }

        if let closest = nearby.first {
            // Camera within enter radius: show or update the banner.
            let absoluteBearing = closest.camera.bearing(from: location.coordinate)
            let relBearing: Double? = userHeading.map {
                (absoluteBearing - $0).truncatingRemainder(dividingBy: 360)
            }
            let normalizedRelBearing = relBearing.map { $0 < 0 ? $0 + 360 : $0 }
            let direction: RelativeDirection = normalizedRelBearing.map { RelativeDirection.from(relativeBearing: $0) } ?? .nearby

            let isNewCamera = activeAlert?.cameraID != closest.camera.osmID

            if isNewCamera {
                cancelExitGrace()

                let isOnCooldown = isCameraOnCooldown(closest.camera.osmID)
                let isMoving = location.speed >= stationarySpeedThreshold

                activeAlert = ProximityAlert(
                    cameraID: closest.camera.osmID,
                    camera: closest.camera,
                    distance: closest.distance,
                    bearing: absoluteBearing,
                    relativeBearing: normalizedRelBearing,
                    relativeDirection: direction,
                    nearbyCount: max(0, nearby.count - 1),
                    enteredAt: Date(),
                    hasTriggeredVeryClose: false
                )

                if enableHaptics && !isOnCooldown && isMoving {
                    triggerEntryHaptic()
                }

                setCameraCooldown(closest.camera.osmID)
                recordEncounter(camera: closest.camera)
                notificationManager.sendProximityAlert(for: closest.camera, distance: closest.distance)

            } else {
                // Same camera: update distance, bearing, and direction in place.
                cancelExitGrace()
                activeAlert?.distance = closest.distance
                activeAlert?.bearing = absoluteBearing
                activeAlert?.relativeBearing = normalizedRelBearing
                activeAlert?.relativeDirection = direction
                activeAlert?.nearbyCount = max(0, nearby.count - 1)

                // "Very close" escalation haptic (one-shot)
                if enableHaptics,
                   closest.distance <= veryCloseRadius,
                   activeAlert?.hasTriggeredVeryClose == false,
                   location.speed >= stationarySpeedThreshold {
                    activeAlert?.hasTriggeredVeryClose = true
                    triggerVeryCloseHaptic()
                }
            }

        } else if activeAlert != nil {
            // No camera within enter radius: check the hysteresis zone.
            if let currentAlertID = activeAlert?.cameraID,
               withinExitRadius.contains(where: { $0.camera.osmID == currentAlertID }) {
                // Still within exit radius: update distance but keep the banner.
                if let match = withinExitRadius.first(where: { $0.camera.osmID == currentAlertID }) {
                    let absoluteBearing = match.camera.bearing(from: location.coordinate)
                    let relBearing: Double? = userHeading.map {
                        (absoluteBearing - $0).truncatingRemainder(dividingBy: 360)
                    }
                    let normalizedRelBearing = relBearing.map { $0 < 0 ? $0 + 360 : $0 }
                    let direction: RelativeDirection = normalizedRelBearing.map { RelativeDirection.from(relativeBearing: $0) } ?? .nearby

                    activeAlert?.distance = match.distance
                    activeAlert?.bearing = absoluteBearing
                    activeAlert?.relativeBearing = normalizedRelBearing
                    activeAlert?.relativeDirection = direction
                }
            } else {
                // Beyond exit radius: keep updating distance while grace is active.
                if let camera = activeAlert?.camera {
                    let cameraLocation = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
                    let currentDistance = location.distance(from: cameraLocation)
                    let absoluteBearing = camera.bearing(from: location.coordinate)
                    let relBearing: Double? = userHeading.map {
                        (absoluteBearing - $0).truncatingRemainder(dividingBy: 360)
                    }
                    let normalizedRelBearing = relBearing.map { $0 < 0 ? $0 + 360 : $0 }
                    let direction: RelativeDirection = normalizedRelBearing.map { RelativeDirection.from(relativeBearing: $0) } ?? .nearby

                    activeAlert?.distance = currentDistance
                    activeAlert?.bearing = absoluteBearing
                    activeAlert?.relativeBearing = normalizedRelBearing
                    activeAlert?.relativeDirection = direction
                }

                if !isInExitGrace {
                    startExitGrace()
                }
            }
        }

        if let liveActivityManager {
            let nearestType = nearby.first?.camera.surveillanceType.rawValue ?? ""
            let nearestDist = nearby.first?.distance ?? -1
            let nearestBearing = nearby.first.map { $0.camera.bearing(from: location.coordinate) } ?? 0
            Task {
                await liveActivityManager.update(
                    nearbyCameraCount: nearby.count,
                    nearestDistance: nearestDist,
                    nearestBearing: nearestBearing,
                    nearestCameraType: nearestType,
                    isTracking: true
                )
            }
        }
    }

    // MARK: - Exit Grace Timer

    private func startExitGrace() {
        isInExitGrace = true
        exitGraceTask?.cancel()
        let grace = exitGraceDuration
        exitGraceTask = Task {
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            activeAlert = nil
            isInExitGrace = false
        }
    }

    private func cancelExitGrace() {
        exitGraceTask?.cancel()
        exitGraceTask = nil
        isInExitGrace = false
    }

    // MARK: - Per-Camera Cooldown

    private func isCameraOnCooldown(_ cameraID: Int64) -> Bool {
        guard let lastEntry = cameraCooldowns[cameraID] else { return false }
        return Date().timeIntervalSince(lastEntry) < cameraCooldownDuration
    }

    private func setCameraCooldown(_ cameraID: Int64) {
        cameraCooldowns[cameraID] = Date()

        // Prune old entries to prevent unbounded growth
        let cutoff = Date().addingTimeInterval(-cameraCooldownDuration * 2)
        cameraCooldowns = cameraCooldowns.filter { $0.value > cutoff }
    }

    // MARK: - Haptics

    private func triggerEntryHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func triggerVeryCloseHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    // MARK: - Camera Selection

    func selectCamera(_ camera: SurveillanceCamera) {
        selectedCamera = camera
        showCameraDetail = true
        cameraPosition = .region(MKCoordinateRegion(
            center: camera.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
    }
}
