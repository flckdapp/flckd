import Foundation

enum VoicePromptKind: Equatable, Sendable {
    case directions, lane, trafficLight, rerouting, camera(CameraVoiceType), preview
}

struct VoicePlaybackContext: Equatable, Sendable {
    var navigating = false
    var tripMuted = false
}

/// One permission policy for producers and the player. Preview is an explicit
/// user action, not automatic speech, and is refused during navigation.
struct VoiceSettings: Equatable, Sendable {
    static let masterKey = "voiceEnabled"
    static let directionsKey = "voiceGuidanceEnabled"
    static let lanesKey = "spokenLaneGuidanceEnabled"
    static let trafficLightsKey = "spokenTrafficLightsEnabled"
    static let reroutingKey = "spokenReroutingEnabled"
    static let camerasKey = "spokenCameraAlertsEnabled"
    static let outsideNavigationKey = "spokenCamerasOutsideNavigation"
    static let legacyCameraModeKey = "spokenCameraAlertMode"

    var master = true
    var directions = true
    var lanes = true
    var trafficLights = true
    var rerouting = true
    var cameras = true
    var outsideNavigation = false
    var cameraTypes = Set(CameraVoiceType.allCases)

    func allows(_ kind: VoicePromptKind, context: VoicePlaybackContext) -> Bool {
        if kind == .preview { return !context.navigating }
        guard master, !context.tripMuted else { return false }
        switch kind {
        case .directions: return directions
        case .lane: return directions && lanes
        case .trafficLight: return directions && trafficLights
        case .rerouting: return rerouting
        case .camera(let type): return cameras && cameraTypes.contains(type) && (context.navigating || outsideNavigation)
        case .preview: return false
        }
    }

    func allows(_ utterance: VoiceUtterance, context: VoicePlaybackContext) -> Bool {
        guard allows(utterance.kind, context: context) else { return false }
        if utterance.kind == .preview { return true }
        if utterance.clips.contains(where: { $0.hasPrefix("lane_") }), !allows(.lane, context: context) { return false }
        if utterance.clips.contains(where: { $0.hasPrefix("at_") || $0.hasPrefix("after_light.") }),
           !allows(.trafficLight, context: context) { return false }
        return true
    }

    static func migrate(_ defaults: UserDefaults = .standard) {
        // Each new key is authoritative once present; a later launch must not
        // undo a preference changed after migration.
        let legacy = defaults.string(forKey: legacyCameraModeKey)
        if defaults.object(forKey: camerasKey) == nil {
            defaults.set(legacy != "off", forKey: camerasKey)
        }
        if defaults.object(forKey: outsideNavigationKey) == nil {
            defaults.set(legacy == "always", forKey: outsideNavigationKey)
        }
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> Self {
        func enabled(_ key: String, fallback: Bool = true) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        let legacy = defaults.string(forKey: legacyCameraModeKey)
        return Self(
            master: enabled(masterKey), directions: enabled(directionsKey), lanes: enabled(lanesKey),
            trafficLights: enabled(trafficLightsKey), rerouting: enabled(reroutingKey),
            cameras: enabled(camerasKey, fallback: legacy != "off"),
            outsideNavigation: enabled(outsideNavigationKey, fallback: legacy == "always"),
            cameraTypes: Set(CameraVoiceType.allCases.filter { enabled($0.storageKey) })
        )
    }
}
