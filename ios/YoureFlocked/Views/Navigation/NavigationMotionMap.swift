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
        context.coordinator.installFollowingPuck(on: map)
        let observer = MapTouchObserver(target: nil, action: nil)
        observer.onBegin = { [weak coordinator = context.coordinator] in coordinator?.beginInteraction() }
        observer.onEnd = { [weak coordinator = context.coordinator] in coordinator?.endInteraction() }
        map.addGestureRecognizer(observer)
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
        private var sceneObserver: NSObjectProtocol?
        private var foregroundObserver: NSObjectProtocol?
        private let followingPuck = NavigationPuckView()
        private var followState = NavigationFollowState()
        private var lastRequestedFollow = true
        private var recenterStart: (time: TimeInterval, camera: MKMapCamera)?

        init(_ parent: NavigationMotionMap) { self.parent = parent; super.init(); puck.title = "You" }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(frame))
            let maximum = Float(map?.window?.windowScene?.screen.maximumFramesPerSecond ?? 120)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
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

        func installFollowingPuck(on map: MKMapView) {
            followingPuck.translatesAutoresizingMaskIntoConstraints = false
            followingPuck.isUserInteractionEnabled = false
            map.addSubview(followingPuck)
            NSLayoutConstraint.activate([
                followingPuck.centerXAnchor.constraint(equalTo: map.centerXAnchor),
                followingPuck.centerYAnchor.constraint(equalTo: map.centerYAnchor),
                followingPuck.widthAnchor.constraint(equalToConstant: 34),
                followingPuck.heightAnchor.constraint(equalToConstant: 34),
            ])
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
            if parent.following != lastRequestedFollow {
                lastRequestedFollow = parent.following
                if parent.following {
                    followState.recenter()
                    recenterStart = (CACurrentMediaTime(), map.camera)
                } else { followState.stopFollowing() }
            }
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
        }

        private func sameGeometry(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }

        @objc private func frame() {
            let now = CACurrentMediaTime()
            guard ready, let map, let pose = motion.sample(at: now) else { return }
            // Observe recognizers directly before *every* camera write. MapKit
            // may report regionWillChange while our setCamera call is nested.
            if mapGestureIsActive(map), followState.following { beginInteraction() }
            let distance = zoom.update(speed: speed, at: now)
            let moving = motion.isMoving(at: now)
            let needsFrame = moving || wasMoving || zoom.isSettling || recenterStart != nil || wasFollowing != followState.canDriveCamera || !lastMapHeading.isFinite
            guard needsFrame else { return }
            wasMoving = moving
            wasFollowing = followState.canDriveCamera
            heading = pose.heading
            UIView.performWithoutAnimation {
                followingPuck.isHidden = false
                map.view(for: puck)?.isHidden = true
                // Following uses a screen-anchored puck. MapKit lays out
                // annotations separately from camera rendering, so moving both
                // coordinates on one callback still permits a screen-space hop.
                if followState.canDriveCamera {
                    var center = pose.coordinate
                    var followDistance = distance
                    var heading = pose.heading
                    var pitch = 45.0
                    if let transition = recenterStart {
                        let t = min(1, max(0, (now - transition.time) / 0.8))
                        let eased = t * t * (3 - 2 * t)
                        let old = transition.camera
                        center = CLLocationCoordinate2D(latitude: old.centerCoordinate.latitude + (center.latitude - old.centerCoordinate.latitude) * eased,
                                                        longitude: old.centerCoordinate.longitude + (center.longitude - old.centerCoordinate.longitude) * eased)
                        followDistance = old.centerCoordinateDistance + (distance - old.centerCoordinateDistance) * eased
                        heading = NavigationMotion.heading(from: old.heading, to: heading, fraction: eased)
                        pitch = old.pitch + (45 - old.pitch) * eased
                        if t >= 1 { recenterStart = nil }
                    }
                    let camera = MKMapCamera(lookingAtCenter: center, fromDistance: followDistance, pitch: pitch, heading: heading)
                    map.setCamera(camera, animated: false)
                }
                positionPuck(pose, on: map)
                if !lastMapHeading.isFinite || abs(map.camera.heading - lastMapHeading) > 0.2 {
                    lastMapHeading = map.camera.heading
                    for host in cameraHosts.values where host.view.window != nil {
                        host.view.superview?.transform = CGAffineTransform(rotationAngle: -map.camera.heading * .pi / 180)
                    }
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if followState.following, mapGestureIsActive(mapView) { beginInteraction() }
        }

        private func mapGestureIsActive(_ view: UIView) -> Bool {
            (view.gestureRecognizers ?? []).contains { !($0 is MapTouchObserver) && ($0.state == .began || $0.state == .changed) }
                || view.subviews.contains { mapGestureIsActive($0) }
        }

        func beginInteraction() {
            followState.beginInteraction()
            recenterStart = nil
            if parent.following {
                lastRequestedFollow = false
                parent.following = false
            }
        }

        func endInteraction() { followState.endInteraction() }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            if !followState.canDriveCamera {
                lastMapHeading = .nan
                if let pose = motion.sample(at: CACurrentMediaTime()) {
                    positionPuck(pose, on: mapView)
                }
            }
        }

        private func positionPuck(_ pose: NavigationMotion.Pose, on map: MKMapView) {
            if followState.canDriveCamera, recenterStart == nil {
                followingPuck.transform = .identity
            } else {
                let point = map.convert(pose.coordinate, toPointTo: map)
                followingPuck.transform = CGAffineTransform(
                    translationX: point.x - map.bounds.midX, y: point.y - map.bounds.midY
                ).rotated(by: (pose.heading - map.camera.heading) * .pi / 180)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation === puck {
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "navigation-puck")
                let artwork = NavigationPuckView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
                view.frame = artwork.frame
                view.addSubview(artwork)
                view.isHidden = true
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

/// Passive touch observer: it never recognizes, prevents, delays or cancels
/// MapKit's gestures. Touch-down yields the camera before pinch/pan can begin.
private final class MapTouchObserver: UIGestureRecognizer {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var touches = Set<ObjectIdentifier>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let first = self.touches.isEmpty
        self.touches.formUnion(touches.map(ObjectIdentifier.init))
        if first { onBegin?() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.subtract(touches.map(ObjectIdentifier.init))
        if self.touches.isEmpty { onEnd?(); state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.removeAll(); onEnd?(); state = .failed
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func reset() { super.reset(); touches.removeAll() }
}

private final class NavigationPuckView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.cornerRadius = 17
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        let inner = UIView(frame: CGRect(x: 3.5, y: 3.5, width: 27, height: 27))
        inner.backgroundColor = UIColor(NavigationPalette.accent)
        inner.layer.cornerRadius = 13.5
        addSubview(inner)
        let icon = UIImageView(image: UIImage(systemName: "location.north.fill"))
        icon.tintColor = .white
        icon.frame = CGRect(x: 10, y: 10, width: 14, height: 14)
        addSubview(icon)
        accessibilityLabel = "Your position"
    }

    required init?(coder: NSCoder) { nil }
}
