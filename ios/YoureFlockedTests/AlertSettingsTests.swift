import CoreLocation
import XCTest
@testable import YoureFlocked

/// Proves the alert settings are respected. Geometry is synthetic, in metres
/// east/north of null island.
final class AlertSettingsTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "AlertSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func point(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: north / 111_320, longitude: east / 111_320)
    }

    private func camera(_ id: Int64, east: Double, north: Double = 0,
                        type: String = "ALPR", direction: String? = nil) -> SurveillanceCamera {
        let p = point(east, north)
        var tags = ["surveillance:type": type]
        if let direction { tags["direction"] = direction }
        return SurveillanceCamera(osmID: id, latitude: p.latitude, longitude: p.longitude, tags: tags)
    }

    private final class Spy: ProximityNotifying {
        var alertsEnabled = true
        var sent: [Int64] = []
        func sendProximityAlert(for camera: SurveillanceCamera, distance: Double) { sent.append(camera.osmID) }
    }

    private func store(with cameras: [SurveillanceCamera]) -> CameraStore {
        let store = CameraStore()
        store.cameras = cameras
        store.lastFetchBounds = BoundingBox(south: -0.01, west: -0.01, north: 0.01, east: 0.01)
        return store
    }

    private var origin: CLLocation {
        CLLocation(coordinate: point(0, 0), altitude: 0, horizontalAccuracy: 5,
                   verticalAccuracy: -1, course: 90, speed: 20, timestamp: Date())
    }

    @MainActor
    private func run(_ cameras: [SurveillanceCamera], radius: Double, mode: AlertMode = .nearCamera,
                     filter: CameraTypeFilter = .all, spy: Spy = Spy()) -> (ProximityAlertEngine, Spy) {
        let engine = ProximityAlertEngine()
        engine.handleLocationUpdate(location: origin, heading: nil, cameraStore: store(with: cameras),
                                    notificationManager: spy, liveActivityManager: nil,
                                    alertRadius: radius, alertMode: mode, enableHaptics: false, filter: filter)
        return (engine, spy)
    }

    // MARK: - Radius

    @MainActor
    func testCameraBeyondFiftyMetreRadiusGivesNoAlertAndNoNotification() {
        let (engine, spy) = run([camera(1, east: 150)], radius: 50)
        XCTAssertNil(engine.activeAlert)
        XCTAssertTrue(spy.sent.isEmpty)
    }

    @MainActor
    func testCameraInsideFiftyMetreRadiusGivesAlertAndNotification() {
        let (engine, spy) = run([camera(1, east: 40)], radius: 50)
        XCTAssertEqual(engine.activeAlert?.cameraID, 1)
        XCTAssertEqual(spy.sent, [1])
    }

    func testLocationManagerLoadsStoredAlertRadius() {
        let key = LocationManager.alertRadiusKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(50.0, forKey: key)
        XCTAssertEqual(LocationManager().alertRadius, 50)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(LocationManager().alertRadius, 200)
    }

    // MARK: - Alert mode

    @MainActor
    func testFieldOfViewModeStaysSilentWhenCameraFacesAway() {
        let facingAway = camera(1, east: 40, direction: "90")
        let (engine, spy) = run([facingAway], radius: 100, mode: .inFieldOfView)
        XCTAssertNil(engine.activeAlert)
        XCTAssertTrue(spy.sent.isEmpty)
        let facingUs = camera(2, east: 40, direction: "270")
        let (engine2, spy2) = run([facingUs], radius: 100, mode: .inFieldOfView)
        XCTAssertEqual(engine2.activeAlert?.cameraID, 2)
        XCTAssertEqual(spy2.sent, [2])
    }

    // MARK: - Enable Alerts

    @MainActor
    func testAlertsEnabledPersistsAcrossInstances() {
        let first = NotificationManager(defaults: defaults)
        XCTAssertTrue(first.alertsEnabled, "defaults to on")
        first.alertsEnabled = false
        XCTAssertFalse(NotificationManager(defaults: defaults).alertsEnabled)
        first.alertsEnabled = true
        XCTAssertTrue(NotificationManager(defaults: defaults).alertsEnabled)
    }

    @MainActor
    func testNotificationIsAdmittedOnlyWhenAlertsAreOnAndAuthorised() {
        let manager = NotificationManager(defaults: defaults)
        let cam = camera(1, east: 10)
        XCTAssertFalse(manager.admitProximityAlert(for: cam), "not authorised yet")
        manager.isAuthorized = true
        manager.alertsEnabled = false
        XCTAssertFalse(manager.admitProximityAlert(for: cam))
        manager.alertsEnabled = true
        XCTAssertTrue(manager.admitProximityAlert(for: cam))
        XCTAssertFalse(manager.admitProximityAlert(for: cam), "five-minute cooldown")
    }

    // MARK: - Type filter

    func testFilterForEverySwitchCombination() {
        let types = ["ALPR": SurveillanceType.alpr, "speed_camera": .speedCamera, "camera": .camera, "guard": .guard_]
        for alprOnly in [false, true] {
            for speed in [false, true] {
                for generic in [false, true] {
                    let filter = CameraTypeFilter(alprOnly: alprOnly, showSpeed: speed, showGeneric: generic)
                    for (raw, type) in types {
                        let expected: Bool
                        switch type {
                        case .alpr: expected = true
                        case .speedCamera: expected = !alprOnly && speed
                        case .camera: expected = !alprOnly && generic
                        default: expected = !alprOnly
                        }
                        XCTAssertEqual(filter.allows(camera(1, east: 0, type: raw)), expected,
                                       "\(raw) alprOnly=\(alprOnly) speed=\(speed) generic=\(generic)")
                    }
                }
            }
        }
        XCTAssertTrue(CameraTypeFilter.all.allows(camera(1, east: 0, type: "nonsense")))
    }

    func testFilterReadsTheKeysSettingsWrites() {
        XCTAssertEqual(CameraTypeFilter.fromDefaults(defaults), .all)
        defaults.set(true, forKey: "showALPROnly")
        defaults.set(false, forKey: "showSpeedCameras")
        defaults.set(false, forKey: "showGenericCameras")
        XCTAssertEqual(CameraTypeFilter.fromDefaults(defaults),
                       CameraTypeFilter(alprOnly: true, showSpeed: false, showGeneric: false))
    }

    @MainActor
    func testFilteredOutCameraProducesNoAlertNotificationOrNearbyEntry() {
        let generic = camera(1, east: 30, type: "camera")
        let filter = CameraTypeFilter(alprOnly: false, showSpeed: true, showGeneric: false)
        let (engine, spy) = run([generic], radius: 100, filter: filter)
        XCTAssertNil(engine.activeAlert)
        XCTAssertTrue(spy.sent.isEmpty)
        XCTAssertTrue(engine.tripStats.isEmpty)
        let (engine2, spy2) = run([generic], radius: 100, filter: .all)
        XCTAssertEqual(engine2.activeAlert?.cameraID, 1)
        XCTAssertEqual(spy2.sent, [1])
    }

    @MainActor
    func testAlprOnlyHidesSpeedCameraEvenWhenSpeedSwitchIsOn() {
        let speed = camera(1, east: 30, type: "speed_camera")
        let (engine, _) = run([speed], radius: 100, filter: CameraTypeFilter(alprOnly: true, showSpeed: true, showGeneric: true))
        XCTAssertNil(engine.activeAlert)
    }

    @MainActor
    func testStoreProximityHonoursFilterAndDefaultKeepsEverything() {
        let s = store(with: [camera(1, east: 30, type: "camera"), camera(2, east: 40)])
        XCTAssertEqual(s.checkProximity(location: origin, alertRadius: 100).count, 2)
        let onlyAlpr = CameraTypeFilter(alprOnly: true, showSpeed: true, showGeneric: true)
        XCTAssertEqual(s.checkProximity(location: origin, alertRadius: 100, filter: onlyAlpr).map(\.camera.osmID), [2])
        XCTAssertEqual(s.cameras.count, 2, "the filter never removes cameras from the store routing reads")
    }

    @MainActor
    func testMapDrawsOnlyCamerasTheFilterAllows() {
        let all = [camera(1, east: 10), camera(2, east: 20, type: "camera"), camera(3, east: 30, type: "speed_camera")]
        let model = MapViewModel()
        XCTAssertEqual(model.annotationContent(from: all, filter: .all).cameras.count, 3)
        let noGeneric = CameraTypeFilter(alprOnly: false, showSpeed: true, showGeneric: false)
        XCTAssertEqual(model.annotationContent(from: all, filter: noGeneric).cameras.map(\.osmID), [1, 3])
    }

    // MARK: - Mutes

    func testPermanentMuteSurvivesNewInstance() {
        NotificationMuteStore(defaults: defaults).mutePermanently(7)
        let reloaded = NotificationMuteStore(defaults: defaults)
        XCTAssertTrue(reloaded.isMuted(7))
        XCTAssertFalse(reloaded.isMuted(8))
        XCTAssertEqual(reloaded.count(), 1)
    }

    func testOneHourMuteExpiresAndIsPruned() {
        let store = NotificationMuteStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.muteForOneHour(5, now: now)
        XCTAssertTrue(NotificationMuteStore(defaults: defaults).isMuted(5, now: now.addingTimeInterval(3599)))
        XCTAssertFalse(store.isMuted(5, now: now.addingTimeInterval(3601)))
        XCTAssertEqual(store.count(now: now.addingTimeInterval(3601)), 0)
        store.mutePermanently(6, now: now.addingTimeInterval(3601))
        let raw = defaults.dictionary(forKey: NotificationMuteStore.temporaryKey) ?? [:]
        XCTAssertTrue(raw.isEmpty, "expired entries are dropped on the next write")
    }

    @MainActor
    func testMutedCameraIsNotNotifiedAndUnmuteAllRestoresIt() {
        let manager = NotificationManager(defaults: defaults)
        manager.isAuthorized = true
        let cam = camera(9, east: 10)
        NotificationMuteStore(defaults: defaults).mutePermanently(9)
        NotificationMuteStore(defaults: defaults).muteForOneHour(10)
        let reloaded = NotificationManager(defaults: defaults)
        reloaded.isAuthorized = true
        XCTAssertEqual(reloaded.mutedCount, 2)
        XCTAssertFalse(reloaded.admitProximityAlert(for: cam))
        XCTAssertFalse(reloaded.admitProximityAlert(for: camera(10, east: 10)))
        XCTAssertTrue(reloaded.admitProximityAlert(for: camera(11, east: 10)))
        reloaded.unmuteAll()
        XCTAssertEqual(reloaded.mutedCount, 0)
        XCTAssertEqual(NotificationMuteStore(defaults: defaults).count(), 0)
        XCTAssertTrue(reloaded.admitProximityAlert(for: cam))
        XCTAssertNotNil(manager)
    }

    func testCameraIDExtractionAcceptsNSNumberAndInt64() {
        let big: Int64 = 9_000_000_000_123
        XCTAssertEqual(NotificationManager.cameraID(from: ["cameraID": big]), big)
        XCTAssertEqual(NotificationManager.cameraID(from: ["cameraID": NSNumber(value: big)]), big)
        XCTAssertEqual(NotificationManager.cameraID(from: ["cameraID": 42]), 42)
        XCTAssertNil(NotificationManager.cameraID(from: ["cameraID": "42"]))
        XCTAssertNil(NotificationManager.cameraID(from: [:]))
    }

    @MainActor
    func testFilterChangeImmediatelyDismissesExistingBanner() {
        let cam = camera(1, east: 30, type: "camera")
        let (engine, spy) = run([cam], radius: 100)
        XCTAssertNotNil(engine.activeAlert)
        engine.handleLocationUpdate(location: origin, heading: nil, cameraStore: store(with: [cam]),
            notificationManager: spy, liveActivityManager: nil, alertRadius: 100, alertMode: .nearCamera,
            enableHaptics: false, filter: CameraTypeFilter(showGeneric: false))
        XCTAssertNil(engine.activeAlert, "Filtered cameras must not survive the exit grace")
    }

    @MainActor
    func testNotificationActionsPersistMutesAndUnmuteClearsCooldown() {
        let manager = NotificationManager(defaults: defaults)
        manager.isAuthorized = true
        let cam = camera(1, east: 10)
        XCTAssertTrue(manager.admitProximityAlert(for: cam))
        manager.handleAction("MUTE_CAMERA", cameraID: cam.id)
        XCTAssertEqual(manager.mutedCount, 1)
        XCTAssertFalse(manager.admitProximityAlert(for: cam))
        manager.unmuteAll()
        XCTAssertTrue(manager.admitProximityAlert(for: cam), "Unmute All takes effect immediately")
        manager.handleAction("MUTE_1H", cameraID: 2)
        XCTAssertTrue(NotificationMuteStore(defaults: defaults).isMuted(2))
    }

    func testDisplaySpeedPreferenceDoesNotDisableRoutingStore() {
        let key = CameraTypeFilter.speedKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertTrue(CameraStore().speedCamerasEnabled, "A display preference must not remove routing input")
    }
}
