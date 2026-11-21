import Foundation
import UIKit
import UserNotifications
import Observation

/// What the proximity engine needs from the notification side. A seam so tests
/// can observe sends without `UNUserNotificationCenter`.
@MainActor
protocol ProximityNotifying: AnyObject {
    var alertsEnabled: Bool { get }
    func sendProximityAlert(for camera: SurveillanceCamera, distance: Double)
}

@Observable
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, ProximityNotifying {

    /// The key Settings' "Enable Alerts" switch persists to.
    static let alertsEnabledKey = "alertsEnabled"

    var isAuthorized: Bool = false

    /// Persisted. iOS relaunches the app in the background for significant
    /// location changes, so an in-memory flag silently turned alerts back on
    /// after the user had turned them off.
    var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Self.alertsEnabledKey) }
    }

    /// Cameras currently muted from notifications. Drives Settings' Unmute row.
    private(set) var mutedCount: Int = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let mutes: NotificationMuteStore
    private var recentlyAlerted: [Int64: Date] = [:]
    private let cooldownInterval: TimeInterval = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mutes = NotificationMuteStore(defaults: defaults)
        self.alertsEnabled = defaults.object(forKey: Self.alertsEnabledKey) as? Bool ?? true
        super.init()
        mutedCount = mutes.count()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            return granted
        } catch {
            isAuthorized = false
            return false
        }
    }

    // MARK: - Notification Categories

    private func registerCategories() {
        let openMap = UNNotificationAction(
            identifier: "OPEN_MAP",
            title: "Show on Map",
            options: [.foreground]
        )
        let mute1h = UNNotificationAction(
            identifier: "MUTE_1H",
            title: "Mute 1 Hour",
            options: []
        )
        let muteCamera = UNNotificationAction(
            identifier: "MUTE_CAMERA",
            title: "Mute This Camera",
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: "CAMERA_PROXIMITY",
            actions: [openMap, mute1h, muteCamera],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Proximity Alerts

    /// Whether a notification may go out for this camera now, recording the
    /// five-minute cooldown when it may.
    func admitProximityAlert(for camera: SurveillanceCamera, now: Date = Date()) -> Bool {
        guard alertsEnabled, isAuthorized else { return false }
        guard !mutes.isMuted(camera.osmID, now: now) else { return false }
        recentlyAlerted = recentlyAlerted.filter { now.timeIntervalSince($0.value) < cooldownInterval }
        guard recentlyAlerted[camera.osmID] == nil else { return false }
        recentlyAlerted[camera.osmID] = now
        return true
    }

    func sendProximityAlert(for camera: SurveillanceCamera, distance: Double) {
        guard admitProximityAlert(for: camera) else { return }

        let data = AlertData(
            osmID: camera.osmID,
            kind: AlertKind(from: camera.surveillanceType),
            manufacturer: camera.manufacturer,
            operatorName: camera.operatorName,
            zone: camera.surveillanceZone,
            latitude: camera.latitude,
            longitude: camera.longitude,
            distance: distance
        )

        Task { @MainActor in
            guard self.alertsEnabled, !self.mutes.isMuted(data.osmID) else { return }
            await Self.buildAndSend(data: data)
        }
    }

    // MARK: - Mutes

    func unmuteAll() {
        mutes.unmuteAll()
        recentlyAlerted.removeAll()
        mutedCount = 0
    }

    func refreshMutes() { mutedCount = mutes.count() }

    /// `userInfo` values that went through a delivered notification come back
    /// as `NSNumber`, so a plain `as? Int64` cast is not enough.
    nonisolated static func cameraID(from userInfo: [AnyHashable: Any]) -> Int64? {
        switch userInfo["cameraID"] {
        case let id as Int64: return id
        case let number as NSNumber: return number.int64Value
        case let id as Int: return Int64(id)
        default: return nil
        }
    }

    private func applyMute(_ cameraID: Int64, permanently: Bool) {
        if permanently { mutes.mutePermanently(cameraID) } else { mutes.muteForOneHour(cameraID) }
        mutedCount = mutes.count()
    }

    // MARK: - Alert Construction

    private enum AlertKind: Sendable, Equatable {
        case alpr, speed, surveillance

        init(from type: SurveillanceType) {
            switch type {
            case .alpr: self = .alpr
            case .speedCamera: self = .speed
            default: self = .surveillance
            }
        }

        var title: String {
            switch self {
            case .alpr: return "ALPR Camera Nearby"
            case .speed: return "Speed Camera Nearby"
            case .surveillance: return "Surveillance Camera Nearby"
            }
        }

        var shortLabel: String {
            switch self {
            case .alpr: return "ALPR"
            case .speed: return "SPEED"
            case .surveillance: return "CAMERA"
            }
        }

        var threadID: String {
            switch self {
            case .alpr: return "proximity.alpr"
            case .speed: return "proximity.speed"
            case .surveillance: return "proximity.surveillance"
            }
        }

        var cardGradient: (UIColor, UIColor) {
            switch self {
            case .alpr: return (UIColor(red: 0.55, green: 0.10, blue: 0.10, alpha: 1),
                                UIColor(red: 0.80, green: 0.27, blue: 0.00, alpha: 1))
            case .speed: return (UIColor(red: 0.48, green: 0.36, blue: 0.00, alpha: 1),
                                 UIColor(red: 0.72, green: 0.53, blue: 0.07, alpha: 1))
            case .surveillance: return (UIColor(red: 0.11, green: 0.19, blue: 0.27, alpha: 1),
                                        UIColor(red: 0.23, green: 0.42, blue: 0.55, alpha: 1))
            }
        }
    }

    private struct AlertData: Sendable {
        let osmID: Int64
        let kind: AlertKind
        let manufacturer: String?
        let operatorName: String?
        let zone: String?
        let latitude: Double
        let longitude: Double
        let distance: Double
    }

    @MainActor
    private static func buildAndSend(data: AlertData) async {
        let useMetric = UserDefaults.standard.bool(forKey: DistanceUnits.storageKey)
        let distanceText: String
        if useMetric {
            distanceText = "\(Int(data.distance))m"
        } else {
            distanceText = "\(Int(data.distance * 3.28084))ft"
        }

        let content = UNMutableNotificationContent()
        content.title = data.kind.title
        content.subtitle = data.manufacturer ?? data.operatorName ?? data.zone ?? ""
        content.body = "\(distanceText) away. Tap to open map."
        content.sound = .default
        content.categoryIdentifier = "CAMERA_PROXIMITY"
        content.threadIdentifier = data.kind.threadID
        content.interruptionLevel = (data.kind == .alpr && data.distance <= 100) ? .timeSensitive : .active
        content.userInfo = [
            "cameraID": data.osmID,
            "latitude": data.latitude,
            "longitude": data.longitude,
        ]

        if let attachment = generateAlertCard(data: data, distanceText: distanceText) {
            content.attachments = [attachment]
        }

        cleanupOldAttachments()

        let request = UNNotificationRequest(
            identifier: "proximity-\(data.osmID)",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Alert Card Image (CoreGraphics, no MapKit)

    @MainActor
    private static func generateAlertCard(data: AlertData, distanceText: String) -> UNNotificationAttachment? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let cgContext = ctx.cgContext

            let (startColor, endColor) = data.kind.cardGradient
            let colors = [startColor.cgColor, endColor.cgColor] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            let paragraphCenter = NSMutableParagraphStyle()
            paragraphCenter.alignment = .center

            let kindLabel = data.kind.shortLabel
            let kindAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.6),
                .paragraphStyle: paragraphCenter,
            ]
            let kindRect = CGRect(x: 0, y: 60, width: size.width, height: 50)
            (kindLabel as NSString).draw(in: kindRect, withAttributes: kindAttrs)

            let distAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 120, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphCenter,
            ]
            let distRect = CGRect(x: 0, y: 150, width: size.width, height: 140)
            (distanceText as NSString).draw(in: distRect, withAttributes: distAttrs)

            let awayAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7),
                .paragraphStyle: paragraphCenter,
            ]
            let awayRect = CGRect(x: 0, y: 290, width: size.width, height: 40)
            ("away" as NSString).draw(in: awayRect, withAttributes: awayAttrs)

            let vendorText = data.manufacturer ?? data.operatorName ?? "Unknown operator"
            let vendorAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .paragraphStyle: paragraphCenter,
            ]
            let vendorRect = CGRect(x: 20, y: 400, width: size.width - 40, height: 40)
            (vendorText as NSString).draw(in: vendorRect, withAttributes: vendorAttrs)

            let circleRect = CGRect(x: size.width / 2 - 15, y: 355, width: 30, height: 30)
            cgContext.setFillColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            cgContext.fillEllipse(in: circleRect)
            cgContext.setFillColor(UIColor.white.withAlphaComponent(0.4).cgColor)
            cgContext.fillEllipse(in: circleRect.insetBy(dx: 8, dy: 8))
        }

        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 32)
        let clipped = renderer.image { ctx in
            ctx.cgContext.addPath(path.cgPath)
            ctx.cgContext.clip()
            image.draw(at: .zero)
        }

        guard let pngData = clipped.pngData() else { return nil }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alert-\(data.osmID)-\(Int(Date().timeIntervalSince1970)).png")

        do {
            try pngData.write(to: fileURL)
            return try UNNotificationAttachment(
                identifier: "card-\(data.osmID)",
                url: fileURL,
                options: [
                    UNNotificationAttachmentOptionsThumbnailClippingRectKey:
                        CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation
                ]
            )
        } catch {
            return nil
        }
    }

    private static func cleanupOldAttachments() {
        let tempDir = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-3600)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix("alert-") {
            guard let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
                  let created = attrs.creationDate,
                  created < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Suppressed while the app is foregrounded because the in-app banner is
    /// already saying the same thing, and two simultaneous warnings for one
    /// camera is worse than one.
    ///
    /// That holds only because the banner is presented above the tab view and
    /// so appears on every screen. It used to be drawn by the map alone, which
    /// made this an unconditional discard: off the map tab the banner was
    /// absent and the notification was thrown away, so nothing warned the
    /// driver at all. If the banner ever becomes conditional again, this has
    /// to become conditional with it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let cameraID = Self.cameraID(from: userInfo)
        let latitude = userInfo["latitude"] as? Double
        let longitude = userInfo["longitude"] as? Double
        await handleAction(action, cameraID: cameraID, latitude: latitude, longitude: longitude)
    }

    func handleAction(_ action: String, cameraID: Int64?, latitude: Double? = nil, longitude: Double? = nil) {
        switch action {
        case "OPEN_MAP", UNNotificationDefaultActionIdentifier:
            if let lat = latitude, let lon = longitude {
                NotificationCenter.default.post(
                    name: .showCameraOnMap,
                    object: nil,
                    userInfo: ["latitude": lat, "longitude": lon]
                )
            }
        case "MUTE_1H":
            if let cameraID { applyMute(cameraID, permanently: false) }
        case "MUTE_CAMERA":
            if let cameraID { applyMute(cameraID, permanently: true) }
        default:
            break
        }

    }
}

extension Notification.Name {
    static let showCameraOnMap = Notification.Name("showCameraOnMap")
}
