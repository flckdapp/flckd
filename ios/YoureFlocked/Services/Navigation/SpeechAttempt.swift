import Foundation

/// One accounting identity per engine call, shared by deadline and completion.
struct SpeechAttempt: Equatable {
    let id = UUID()
    let key: SpeechKey
    let generation: Int
    let window: Int
    let background: Bool
    let activation: Int
    var missedDeadline = false
    var counted = false

    func isEligible(generation: Int, window: Int, allowed: Set<SpeechKey>, common: Set<SpeechKey>) -> Bool {
        self.generation == generation && allowed.contains(key)
    }

    mutating func account(success: Bool, deadlineMiss: Bool, breaker: inout BackgroundSpeechBreaker) {
        missedDeadline = missedDeadline || deadlineMiss
        guard !counted else { return }
        counted = true
        if background, activation == breaker.activation { breaker.record(success: success, deadlineMiss: missedDeadline) }
    }
}

/// A playback deadline belongs to the request waiting for audio, not to the
/// render occupying the worker. Queued requests and foreground-started renders
/// must therefore count against the breaker when their deadline expires locked.
struct SpeechPlaybackRequest {
    let id = UUID()
    let key: SpeechKey
    let generation: Int
    private(set) var counted = false

    mutating func deadline(breaker: inout BackgroundSpeechBreaker, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !counted, !breaker.foreground else { return false }
        counted = true
        breaker.record(success: false, deadlineMiss: true, now: now)
        return true
    }
}
