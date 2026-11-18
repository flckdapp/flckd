import Foundation

enum PromptVoice: String, CaseIterable, Sendable {
    case male, female
    static let storageKey = "navigationPromptVoice"

    var title: String {
        switch self {
        case .male: "Male"
        case .female: "Female"
        }
    }

    var name: String {
        switch self {
        case .male: "Eric"
        case .female: "Matilda"
        }
    }

    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .male
    }

    func url(for key: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: key, withExtension: "m4a", subdirectory: "VoicePrompts/\(rawValue)")
    }
}
