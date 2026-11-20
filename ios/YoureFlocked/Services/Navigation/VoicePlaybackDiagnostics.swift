#if DEBUG
import Foundation

/// Text-free counters used by local UI tests; absent from shipped builds.
@MainActor
enum VoicePlaybackDiagnostics {
    static var liveCount = 0
    static var fallbackCount = 0
    static func record(live: Bool, fallback: Bool) {
        if live { liveCount += 1 }
        if fallback { fallbackCount += 1 }
    }
}
#endif
