import Foundation
import CoreLocation
import Observation
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

// MARK: - Proximity Alert Engine

/// Owns proximity alerting: which camera is being warned about, the
/// hysteresis and cooldown around that decision, the haptics, and the trip
/// tally.
///
/// Lives at app scope rather than on a view. It used to sit in
/// `MapViewModel`, which a view owns, so warnings only surfaced while the map
/// was on screen; a driver with a route open was told nothing. Alerting is the
/// app's primary job and cannot depend on which tab is visible.
@Observable @MainActor
final class ProximityAlertEngine {

    /// Refetch once the user has travelled this fraction of the fetch radius
    /// from the centre of what's cached, leaving the rest as headroom ahead.
    private let cameraRefreshFraction: Double = 0.5

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

    /// The map's follow mode is the proxy for "a trip is under way", and it
    /// lives on the map view model, so it is passed in rather than reached for.
    func checkTripEnd(isFollowingUser: Bool) {
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
        refreshCamerasIfNeeded(around: location.coordinate, cameraStore: cameraStore)

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

    // MARK: - Keeping Cameras Current

    /// Fetches cameras for where the user actually is, as they move.
    ///
    /// Camera data used to be captured once, when a route was planned or the
    /// map first appeared, and never refreshed. Driving out of that box meant
    /// every camera beyond it was unknown: not avoided when routing, and not
    /// warned about, with nothing to indicate anything was missing.
    ///
    /// Distance travelled is the trigger rather than a timer, so it scales
    /// with speed and does nothing at all while parked.
    ///
    /// The decision reads `cameraStore.lastFetchBounds`, which only advances
    /// on a fetch that actually completed, rather than a copy kept here. The
    /// store throttles and can drop a request; against its real state a
    /// dropped fetch is simply retried on the next location update instead of
    /// being lost until the user has travelled another full step.
    private func refreshCamerasIfNeeded(
        around coordinate: CLLocationCoordinate2D,
        cameraStore: CameraStore
    ) {
        guard let covered = cameraStore.lastFetchBounds else {
            Task { await cameraStore.fetchCameras(around: coordinate) }
            return
        }

        let centre = CLLocation(
            latitude: (covered.north + covered.south) / 2,
            longitude: (covered.east + covered.west) / 2
        )
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let step = cameraStore.fetchRadiusKm * 1000 * cameraRefreshFraction
        guard here.distance(from: centre) >= step else { return }

        Task { await cameraStore.fetchCameras(around: coordinate) }
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
}
