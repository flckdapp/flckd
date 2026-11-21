#if DEBUG
import Foundation

/// Text-free counters used by local UI tests; absent from shipped builds.
@MainActor
enum VoicePlaybackDiagnostics {
    static var liveCount = 0
    static var recordedCount = 0
    static var openingCount = 0
    static var skipCount = 0
    static func record(live: Bool, recorded: Bool, opening: Bool) {
        if live { liveCount += 1 }
        if recorded { recordedCount += 1 }
        if opening && live { openingCount += 1 }
    }
}
#endif
