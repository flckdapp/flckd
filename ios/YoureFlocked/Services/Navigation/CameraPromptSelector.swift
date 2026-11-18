import Foundation

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

enum CameraPromptSelector {
    enum Event { case entry, passing }
    static let forms = ["ahead", "right", "left", "nearby", "500ft", "1000ft", "quarter_mi", "200m", "300m", "400m", "passing", "in_view"]
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
        settings: VoiceSettings, context: VoicePlaybackContext, units: DistanceUnits = .imperial
    ) -> String? {
        guard let type = type(for: camera), settings.allows(.camera(type), context: context) else { return nil }
        let prefix = "cam.\(type.rawValue)."
        if event == .passing { return prefix + "passing" }
        if inFieldOfView { return prefix + "in_view" }
        guard direction != .behind else { return nil }
        if nearbyCount >= 1 {
            return "cam.cameras_ahead_" + (nearbyCount == 1 ? "2" : nearbyCount == 2 ? "3" : "many")
        }
        if direction == .ahead, distance >= (units == .metric ? 200 : 300) {
            let distances = units == .metric
                ? [(key: "200m", meters: 200.0), (key: "300m", meters: 300.0), (key: "400m", meters: 400.0)]
                : Array(GuidancePromptSelector.distances.prefix(3))
            let key = distances.min { abs($0.meters - distance) < abs($1.meters - distance) }?.key ?? "1000ft"
            return prefix + key
        }
        return prefix + direction.rawValue.lowercased()
    }
}
