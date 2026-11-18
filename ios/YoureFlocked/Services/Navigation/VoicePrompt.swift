import Foundation

/// An indivisible prompt: priority applies between utterances, never between clips.
struct VoiceUtterance: Equatable, Sendable {
    enum Priority: Sendable { case guidance, camera, sample }
    var clips: [String]
    var fallbackText: String = ""
    var language: String = "en-US"
    var voice: PromptVoice = .male
    var priority: Priority = .guidance
    var kind: VoicePromptKind = .directions
    var createdAt: TimeInterval
    var cameraTargets = Set<Int64>()
    var cameraRequiresView = false

    static func preview(voice: PromptVoice, now: TimeInterval, units: DistanceUnits = .imperial) -> Self {
        Self(clips: [units == .metric ? "200m.turn_right" : "500ft.turn_right", "lane_right", "cam.flock.ahead"], voice: voice,
             priority: .sample, kind: .preview, createdAt: now)
    }
}

struct VoicePromptQueue {
    static let cameraLifetime: TimeInterval = 5
    private(set) var pending: [VoiceUtterance] = []

    mutating func enqueue(_ utterance: VoiceUtterance) {
        if utterance.kind == .preview { remove(.sample) }
        pending.append(utterance)
    }

    mutating func next(now: TimeInterval) -> VoiceUtterance? {
        pending.removeAll { $0.priority == .camera && now - $0.createdAt > Self.cameraLifetime }
        guard !pending.isEmpty else { return nil }
        let index = pending.firstIndex { $0.priority == .guidance } ?? pending.startIndex
        return pending.remove(at: index)
    }

    mutating func remove(_ priority: VoiceUtterance.Priority) {
        pending.removeAll { $0.priority == priority }
    }

    mutating func clear() { pending.removeAll() }

    mutating func removeDisallowed(settings: VoiceSettings, context: VoicePlaybackContext) {
        pending.removeAll { !settings.allows($0, context: context) }
    }

    mutating func removeInvalidCameras(_ eligibility: CameraSpeechEligibility) {
        pending.removeAll { !eligibility.allows($0) }
    }
}

/// Sample positions, not completion timers, determine every join.
enum VoiceTimeline {
    static let sentenceGap: TimeInterval = 0.350
    static let intraSentenceGap: TimeInterval = 0.120
    static let fadeDuration: TimeInterval = 0.008

    struct Segment: Equatable {
        let clipIndex: Int
        let startFrame: Int
        let frameCount: Int
    }

    static func segments(lengths: [Int], sampleRate: Double, gap: TimeInterval = sentenceGap) -> [Segment] {
        var position = 0
        return lengths.enumerated().map { index, count in
            defer { position += count + Int((gap * sampleRate).rounded()) }
            return Segment(clipIndex: index, startFrame: position, frameCount: count)
        }
    }
}
