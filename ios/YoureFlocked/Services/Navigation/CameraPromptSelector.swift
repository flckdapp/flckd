import Foundation

enum CameraVoiceMode: String, CaseIterable, Sendable {
    case off, navigating, always
    static let storageKey = "spokenCameraAlertMode"
    var title: String {
        switch self {
        case .off: "Off"
        case .navigating: "While navigating"
        case .always: "Always"
        }
    }
}

enum CameraVoiceType: String, CaseIterable, Sendable {
    case flock, camera, speed, gunshot
    var storageKey: String { "spokenCamera_\(rawValue)" }
    var title: String {
        switch self {
        case .flock: "Flock cameras"
        case .camera: "Other surveillance cameras"
        case .speed: "Speed cameras"
        case .gunshot: "Gunshot detectors"
        }
    }
}

struct CameraVoiceSettings {
    var mode: CameraVoiceMode = .navigating
    var enabledTypes: Set<CameraVoiceType> = Set(CameraVoiceType.allCases)

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> Self {
        Self(
            mode: CameraVoiceMode(rawValue: defaults.string(forKey: CameraVoiceMode.storageKey) ?? "") ?? .navigating,
            enabledTypes: Set(CameraVoiceType.allCases.filter {
                defaults.object(forKey: $0.storageKey) == nil || defaults.bool(forKey: $0.storageKey)
            })
        )
    }

    func allows(_ type: CameraVoiceType, navigating: Bool, muted: Bool) -> Bool {
        !muted && enabledTypes.contains(type) && (mode == .always || (mode == .navigating && navigating))
    }
}

enum CameraPromptSelector {
    enum Event { case entry, passing }
    static let forms = ["ahead", "right", "left", "nearby", "500ft", "1000ft", "quarter_mi", "passing", "in_view"]
    static var allKeys: Set<String> {
        Set(CameraVoiceType.allCases.flatMap { type in forms.map { "cam.\(type.rawValue).\($0)" } }
            + ["cam.cameras_ahead_2", "cam.cameras_ahead_3", "cam.cameras_ahead_many"])
    }

    static func type(for camera: SurveillanceCamera) -> CameraVoiceType? {
        switch camera.surveillanceType {
        case .alpr:
            return [camera.tags["manufacturer"], camera.tags["brand"]].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains("flock") } ? .flock : .camera
        case .camera: return .camera
        case .speedCamera: return .speed
        case .gunshotDetector: return .gunshot
        case .guard_, .unknown: return nil
        }
    }

    static func select(
        camera: SurveillanceCamera, direction: RelativeDirection, distance: Double,
        nearbyCount: Int, event: Event, inFieldOfView: Bool,
        settings: CameraVoiceSettings, navigating: Bool, muted: Bool
    ) -> String? {
        guard let type = type(for: camera), settings.allows(type, navigating: navigating, muted: muted) else { return nil }
        let prefix = "cam.\(type.rawValue)."
        if event == .passing { return prefix + "passing" }
        if inFieldOfView { return prefix + "in_view" }
        guard direction != .behind else { return nil }
        if nearbyCount >= 1 {
            return "cam.cameras_ahead_" + (nearbyCount == 1 ? "2" : nearbyCount == 2 ? "3" : "many")
        }
        if direction == .ahead, distance >= 300 {
            let distances = GuidancePromptSelector.distances.prefix(3)
            let key = distances.min { abs($0.meters - distance) < abs($1.meters - distance) }?.key ?? "1000ft"
            return prefix + key
        }
        return prefix + direction.rawValue.lowercased()
    }
}
