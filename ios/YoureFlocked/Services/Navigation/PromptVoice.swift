import Foundation

enum PromptVoice: String, CaseIterable, Sendable {
    case male, female
    static let storageKey = "navigationPromptVoice"

    var name: String {
        switch self {
        case .male: "Eric"
        case .female: "Jessica"
        }
    }

    static var selected: Self {
        NavigationVoice.selected().recording ?? .male
    }

    func url(for key: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: key, withExtension: "m4a", subdirectory: "VoicePrompts/\(rawValue)")
    }
}
