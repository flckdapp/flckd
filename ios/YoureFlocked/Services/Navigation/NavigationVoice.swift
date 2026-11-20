import Foundation

enum NavigationVoice: String, CaseIterable, Sendable {
    case easton, harper, eric, jessica
    static let storageKey = "navigationVoice"
    static let defaultVoice = Self.easton

    var name: String { rawValue.capitalized }
    var live: Bool { self == .easton || self == .harper }
    var recorded: PromptVoice { self == .harper || self == .jessica ? .female : .male }
    var phononName: String? { live ? name : nil }

    static func selected(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? defaultVoice
    }
}

/// Legacy names are intentional: these are the keys/path old builds wrote.
enum VoiceMigration {
    static let obsoleteKeys = ["voiceEngine", "kokoroPreset", "kokoroSayStreetNames", "kokoroMeasuredRTF", "kokoroMeasuredPack"]

    static func selection(current: String?, oldEngine: String?, oldPreset: String?, recorded: String?) -> NavigationVoice {
        if let current, let voice = NavigationVoice(rawValue: current) { return voice }
        if oldEngine == "recorded" { return recorded == "female" ? .jessica : .eric }
        if oldEngine == "kokoro" || oldPreset != nil { return .defaultVoice }
        if recorded == "male" { return .eric }
        if recorded == "female" { return .jessica }
        return .defaultVoice
    }

    static func run(defaults: UserDefaults = .standard, support: URL = .applicationSupportDirectory) throws {
        migratePreferences(defaults: defaults)
        try removeLegacyPack(support: support)
    }

    static func migratePreferences(defaults: UserDefaults = .standard) {
        let voice = selection(current: defaults.string(forKey: NavigationVoice.storageKey),
                              oldEngine: defaults.string(forKey: "voiceEngine"),
                              oldPreset: defaults.string(forKey: "kokoroPreset"),
                              recorded: defaults.string(forKey: PromptVoice.storageKey))
        defaults.set(voice.rawValue, forKey: NavigationVoice.storageKey)
        (obsoleteKeys + [PromptVoice.storageKey]).forEach(defaults.removeObject(forKey:))
    }

    static func removeLegacyPack(support: URL = .applicationSupportDirectory) throws {
        let old = support.appendingPathComponent("voice/kokoro", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
    }
}
