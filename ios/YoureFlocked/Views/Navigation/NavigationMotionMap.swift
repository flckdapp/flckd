import MapKit
import SwiftUI
import QuartzCore

/// The display link changes only the existing puck and camera. Camera warning
/// annotations and route overlays are reconciled at GPS rate, never per frame.
struct NavigationMotionMap: UIViewRepresentable {
    let snapshot: NavigationSnapshot
    @Binding var following: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        context.coordinator.map = map
        map.addAnnotation(context.coordinator.puck)
        context.coordinator.start()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(snapshot)
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NavigationMotionMap
        weak var map: MKMapView?
        let puck = MKPointAnnotation()
        var link: CADisplayLink?
        private var motion = NavigationMotion()
        private var zoom = NavigationZoom()
        private var speed: Double?
        private var timestamp: Date?
        private var cameras: [SurveillanceCamera] = []
        private var cameraAnnotations: [MKPointAnnotation] = []
        private var cameraModels: [ObjectIdentifier: SurveillanceCamera] = [:]
        private var geometry: [CLLocationCoordinate2D] = []
        private var destination: MKPointAnnotation?
        private var heading = 0.0
        private var ready = false
        private var cameraHosts: [ObjectIdentifier: UIHostingController<CameraMarkerView>] = [:]
        private var wasFollowing = false
        private var wasMoving = false
        private var lastMapHeading = Double.nan
        private var renderRoute: [CLLocationCoordinate2D] = []
        private var annotationCenter: CLLocationCoordinate2D?
        private var cameraUpdate = false
        private var sceneObserver: NSObjectProtocol?
        private var foregroundObserver: NSObjectProtocol?

        init(_ parent: NavigationMotionMap) { self.parent = parent; super.init(); puck.title = "You" }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20)
            link.add(to: .main, forMode: .common)
            self.link = link
            sceneObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.link?.isPaused = true }
            }
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.link?.isPaused = false }
            }
        }

        func stop() {
            link?.invalidate()
            if let sceneObserver { NotificationCenter.default.removeObserver(sceneObserver) }
            if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
            sceneObserver = nil
            foregroundObserver = nil
        }

        func update(_ snapshot: NavigationSnapshot) {
            guard let map else { return }
            link?.isPaused = UIApplication.shared.applicationState == .background
            if cameras != snapshot.cameras {
                map.removeAnnotations(cameraAnnotations)
                cameras = snapshot.cameras
                cameraModels.removeAll()
                cameraHosts.removeAll()
                annotationCenter = nil
                cameraAnnotations = cameras.map { camera in
                    let annotation = MKPointAnnotation()
                    annotation.coordinate = camera.coordinate
                    annotation.title = camera.displayName
                    cameraModels[ObjectIdentifier(annotation)] = camera
                    return annotation
                }
            }
            if let here = snapshot.userLocation?.coordinates.clLocationCoordinate2D,
               annotationCenter.map({ NavigationMotion.distance($0, here) >= 1000 }) ?? true {
                annotationCenter = here
                // Reconcile at kilometre boundaries, not display ticks. The
                // five-kilometre margin covers the speed-dependent viewport.
                let nearby = cameraAnnotations.filter { NavigationMotion.distance(here, $0.coordinate) < 5000 }
                let wanted = Set(nearby.map(ObjectIdentifier.init))
                let shown = map.annotations.filter { cameraModels[ObjectIdentifier($0)] != nil }
                let existing = Set(shown.map(ObjectIdentifier.init))
                map.removeAnnotations(shown.filter { !wanted.contains(ObjectIdentifier($0)) })
                cameraHosts = cameraHosts.filter { wanted.contains($0.key) }
                map.addAnnotations(nearby.filter { !existing.contains(ObjectIdentifier($0)) })
            }
            if !sameGeometry(geometry, snapshot.remainingGeometry) {
                geometry = snapshot.remainingGeometry
                map.removeOverlays(map.overlays)
                if geometry.count > 1 {
                    let casing = MKPolyline(coordinates: geometry, count: geometry.count)
                    casing.title = "route-casing"
                    map.addOverlay(casing)
                    map.addOverlay(MKPolyline(coordinates: geometry, count: geometry.count))
                }
            }
            if !sameGeometry(renderRoute, snapshot.motionGeometry) { renderRoute = snapshot.motionGeometry }
            if let coordinate = snapshot.destinationCoordinate,
               destination.map({ $0.coordinate.latitude != coordinate.latitude || $0.coordinate.longitude != coordinate.longitude }) ?? true {
                if let destination { map.removeAnnotation(destination) }
                let pin = MKPointAnnotation(); pin.coordinate = coordinate; pin.title = snapshot.destinationName
                destination = pin; map.addAnnotation(pin)
            }
            guard let location = snapshot.userLocation, location.timestamp != timestamp else { return }
            timestamp = location.timestamp
            speed = location.speed?.value
            let course = location.courseOverGround.map { Double($0.degrees) } ?? heading
            motion.receive(.init(coordinate: location.coordinates.clLocationCoordinate2D, heading: course),
                           at: CACurrentMediaTime(), route: renderRoute.isEmpty ? geometry : renderRoute, onRoute: snapshot.isOnRoute)
            ready = true
            frame()
        }

        private func sameGeometry(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }

        @objc private func frame() {
            let now = CACurrentMediaTime()
            guard ready, let map, let pose = motion.sample(at: now) else { return }
            let distance = zoom.update(speed: speed, at: now)
            let moving = motion.isMoving(at: now)
            let needsFrame = moving || wasMoving || zoom.isSettling || wasFollowing != parent.following || !lastMapHeading.isFinite
            guard needsFrame else { return }
            wasMoving = moving
            wasFollowing = parent.following
            heading = pose.heading
            UIView.performWithoutAnimation {
                puck.coordinate = pose.coordinate
                if parent.following {
                    cameraUpdate = true
                    let camera = MKMapCamera(lookingAtCenter: pose.coordinate, fromDistance: distance, pitch: 45, heading: pose.heading)
                    map.setCamera(camera, animated: false)
                    cameraUpdate = false
                }
                map.view(for: puck)?.transform = CGAffineTransform(rotationAngle: (pose.heading - map.camera.heading) * .pi / 180)
                if !lastMapHeading.isFinite || abs(map.camera.heading - lastMapHeading) > 0.2 {
                    lastMapHeading = map.camera.heading
                    for host in cameraHosts.values where host.view.window != nil {
                        host.view.superview?.transform = CGAffineTransform(rotationAngle: -map.camera.heading * .pi / 180)
                    }
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard !cameraUpdate else { return }
            func gestures(in view: UIView) -> [UIGestureRecognizer] {
                (view.gestureRecognizers ?? []) + view.subviews.flatMap { gestures(in: $0) }
            }
            let touched = gestures(in: mapView).contains { gesture in gesture.state == .began || gesture.state == .changed }
            if touched, parent.following { parent.following = false }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            if !parent.following {
                lastMapHeading = .nan
                if let pose = motion.sample(at: CACurrentMediaTime()) {
                    mapView.view(for: puck)?.transform = CGAffineTransform(rotationAngle: (pose.heading - mapView.camera.heading) * .pi / 180)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation === puck {
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "navigation-puck")
                view.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
                view.backgroundColor = .white; view.layer.cornerRadius = 17
                view.layer.shadowOpacity = 0.25; view.layer.shadowRadius = 3; view.layer.shadowOffset = CGSize(width: 0, height: 1)
                let inner = UIView(frame: CGRect(x: 3.5, y: 3.5, width: 27, height: 27))
                inner.backgroundColor = UIColor(NavigationPalette.accent); inner.layer.cornerRadius = 13.5
                view.addSubview(inner)
                let icon = UIImageView(image: UIImage(systemName: "location.north.fill"))
                icon.tintColor = .white; icon.frame = CGRect(x: 10, y: 10, width: 14, height: 14)
                view.addSubview(icon); view.accessibilityLabel = "Your position"
                return view
            }
            if let camera = cameraModels[ObjectIdentifier(annotation)] {
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "camera-warning")
                let host = UIHostingController(rootView: CameraMarkerView(camera: camera))
                cameraHosts[ObjectIdentifier(annotation)] = host
                host.view.backgroundColor = .clear; host.view.frame = CGRect(x: 0, y: 0, width: 88, height: 88)
                view.frame = host.view.frame; view.addSubview(host.view)
                return view
            }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "destination")
            view.markerTintColor = UIColor(NavigationPalette.accent)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            let casing = polyline.title == "route-casing"
            renderer.strokeColor = casing ? .white : UIColor(NavigationPalette.accent)
            renderer.lineWidth = casing ? 10 : 7
            renderer.lineCap = .round; renderer.lineJoin = .round
            return renderer
        }
    }
}
