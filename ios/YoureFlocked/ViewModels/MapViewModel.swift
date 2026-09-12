import Foundation
import SwiftUI
import MapKit
import CoreLocation
import UIKit


// MARK: - Map View Model

/// Drives the main map view: camera position, visible region, filtering,
/// clustering and fetch triggers. Proximity alerting lives in
/// `ProximityAlertEngine` at app scope, because it has to keep working when
/// the map isn't on screen.
@Observable @MainActor
final class MapViewModel {

    // MARK: - Map State

    var cameraPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    var visibleRegion: MKCoordinateRegion?
    var selectedCamera: SurveillanceCamera?
    var showCameraDetail: Bool = false
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
