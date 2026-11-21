import Foundation

enum VoiceRenderPolicy {
    /// Guidance tolerates up to ~60 m drift at highway speed. Opening includes
    /// model loading; it is optional speech, never a gate on navigation startup.
    static let deadline: TimeInterval = 2
    static let openingDeadline: TimeInterval = 8
    static let utteranceLimit: TimeInterval = 5
    static let cacheByteLimit = 64 * 1_024 * 1_024
    static func remaining(_ utterance: VoiceUtterance, now: TimeInterval) -> TimeInterval {
        let bound = utterance.priority == .camera ? VoicePromptQueue.cameraLifetime : utterance.isOpening ? openingDeadline : deadline
        return max(0, bound - max(0, now - utterance.createdAt))
    }

    enum State: Equatable { case ready, pending, failed }
    enum Decision: Equatable { case live, wait, recorded, skip }

    static func decide(liveVoice: Bool, state: State, elapsed: TimeInterval,
                       thermal: ProcessInfo.ThermalState) -> Decision {
        guard liveVoice else { return .recorded }
        guard thermal != .critical else { return .skip }
        if elapsed > deadline { return .skip }
        if state == .ready { return .live }
        if state == .failed || elapsed >= deadline { return .skip }
        return .wait
    }

    static func fits(audio: Double, priority: VoiceUtterance.Priority) -> Bool {
        // Named directions commonly take more than three seconds. Camera
        // lifetime limits the camera, not otherwise valid guidance audio.
        audio > 0 && audio <= utteranceLimit
    }

    static func shouldYield(waiting: VoiceUtterance, isPlaying: Bool, incoming: VoiceUtterance) -> Bool {
        waiting.liveVoice?.live == true && waiting.priority == .guidance && !isPlaying && incoming.priority == .camera
    }
}

struct GuidanceContext: Equatable, Sendable {
    let route: UUID
    let step: Int
}

struct LiveGuidanceFreshness {
    var context: GuidanceContext?
    var latest: UUID?
    func allows(_ utterance: VoiceUtterance) -> Bool {
        guard utterance.liveVoice?.live == true, utterance.priority == .guidance else { return true }
        return (utterance.guidanceContext == nil || utterance.guidanceContext == context)
            && (utterance.isOpening || latest == nil || latest == utterance.playbackID)
    }
}

struct BackgroundSpeechBreaker: Equatable {
    static let threshold = 3
    static let cooldown: TimeInterval = 60
    private(set) var failures = 0
    private(set) var foreground = true
    private(set) var activation = 0
    private(set) var retryAt: TimeInterval?
    private(set) var probing = false
    var allowsRender: Bool { canAttempt(now: ProcessInfo.processInfo.systemUptime) }

    func canAttempt(now: TimeInterval) -> Bool {
        foreground || retryAt == nil || (!probing && now >= (retryAt ?? 0))
    }

    mutating func beginAttempt(now: TimeInterval) -> Bool {
        guard canAttempt(now: now) else { return false }
        if !foreground, retryAt != nil { probing = true }
        return true
    }

    mutating func setForeground(_ value: Bool) {
        foreground = value
        if value { failures = 0; activation += 1; retryAt = nil; probing = false }
    }

    mutating func record(success: Bool, deadlineMiss: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !foreground else { return }
        if probing {
            probing = false
            if success { failures = 0; retryAt = nil }
            else { failures = Self.threshold; retryAt = now + Self.cooldown }
            return
        }
        guard retryAt == nil else { return }
        if success && !deadlineMiss { failures = 0 }
        else {
            failures = min(Self.threshold, failures + 1)
            if failures == Self.threshold { retryAt = now + Self.cooldown }
        }
    }

    mutating func completeProbe(success: Bool, now: TimeInterval) {
        guard !foreground else { return }
        probing = false
        if success { failures = 0; retryAt = nil }
        else { failures = Self.threshold; retryAt = now + Self.cooldown }
    }
}

struct SpeechKey: Hashable, Sendable {
    let voice: NavigationVoice
    let sentences: [String]
}

/// Bounded PCM only. Window changes remove route text even when the LRU budget
/// would allow it to survive. Common keys contain generic fixed prompts only.
struct SpeechCache {
    private(set) var audio: [SpeechKey: [Float]] = [:]
    private var order: [SpeechKey] = []
    private(set) var bytes = 0
    var limit = VoiceRenderPolicy.cacheByteLimit
    // Fixed camera prompts cannot be crowded out by route-specific names.
    var reserved = Set<SpeechKey>()

    mutating func insert(_ pcm: [Float], for key: SpeechKey, protecting protected: Set<SpeechKey> = []) {
        remove(key)
        let cost = pcm.count * MemoryLayout<Float>.stride
        guard cost <= limit else { return }
        while bytes + cost > limit {
            guard let oldest = order.first(where: { !protected.contains($0) && !reserved.contains($0) }) else { return }
            remove(oldest)
        }
        audio[key] = pcm
        order.append(key)
        bytes += cost
    }

    mutating func retain(_ keys: Set<SpeechKey>) {
        for key in order where !keys.contains(key) { remove(key) }
    }

    mutating func clear() { audio.removeAll(); order.removeAll(); bytes = 0 }

    private mutating func remove(_ key: SpeechKey) {
        if let old = audio.removeValue(forKey: key) { bytes -= old.count * MemoryLayout<Float>.stride }
        order.removeAll { $0 == key }
    }
}

enum PromptSpeech {
    /// Preserve the maneuver and enrichment clips; remove only the road name,
    /// then the exit number. Deduplicate when the full prompt was already bare.
    static func variants(_ utterance: VoiceUtterance) -> [(variant: SpeechVariant, sentences: [String])] {
        guard let full = sentences(utterance) else { return [] }
        var result: [(SpeechVariant, [String])] = [(.full, full)]
        guard utterance.priority == .guidance, !utterance.isOpening else { return result }
        var shorter = utterance
        shorter.roadName = nil
        if let numbered = sentences(shorter), numbered != full,
           utterance.exitNumber != nil {
            result.append((.numberOnly, numbered))
        }
        shorter.exitNumber = nil
        if let bare = sentences(shorter), !result.contains(where: { $0.1 == bare }) {
            result.append((.nameFree, bare))
        }
        return result
    }

    static func sentences(_ utterance: VoiceUtterance) -> [String]? {
        var text: [String] = []
        if utterance.clips.isEmpty {
            guard PhononSentences.accepts(utterance.fallbackText) else { return nil }
            return PhononSentences.split(utterance.fallbackText)
        }
        for (index, key) in utterance.clips.enumerated() {
            guard let base = PromptText.sentence(for: key) else { return nil }
            if index == 0, let name = utterance.roadName {
                if let named = SpokenRoadName.sentences(firstKey: key, bannerText: name,
                                                        exitNumber: utterance.exitNumber).first {
                    text.append(named.text)
                    continue
                }
                // Bare final actions have the same connector as approaches.
                let action = key.split(separator: ".", maxSplits: 1).last.map(String.init) ?? key
                if let connector = SpokenRoadName.connector(forAction: action),
                   let words = SpokenRoadName.candidate(from: name).flatMap(SpokenRoadName.spoken), base.hasSuffix(".") {
                    let numbered: String
                    if (action == "exit_right" || action == "exit_left"),
                       let exit = utterance.exitNumber.flatMap(SpokenRoadName.exitWords) {
                        numbered = base.dropLast().replacingOccurrences(of: "take the exit", with: "take exit \(exit)")
                            .replacingOccurrences(of: "Take the exit", with: "Take exit \(exit)")
                    } else { numbered = String(base.dropLast()) }
                    text.append("\(numbered) \(connector) \(words).")
                    continue
                }
            }
            if index == 0, let exit = utterance.exitNumber,
               let numbered = SpokenRoadName.sentences(firstKey: key, bannerText: "", exitNumber: exit).first {
                text.append(numbered.text)
            } else if index == 0, (key == "exit_right" || key == "exit_left"),
                      let exit = utterance.exitNumber.flatMap(SpokenRoadName.exitWords) {
                text.append("Take exit \(exit) on the \(key == "exit_right" ? "right" : "left").")
            } else { text.append(base) }
        }
        guard text.allSatisfy(PhononSentences.accepts) else { return nil }
        return text.flatMap(PhononSentences.split)
    }
}

struct SpeechStats: Equatable, Sendable {
    var requested = 0
    var spoken = 0
    var named = 0
    var skipped: [String: Int] = [:]
    mutating func request(_ utterance: VoiceUtterance) {
        guard utterance.liveVoice?.live == true, utterance.priority != .sample else { return }
        requested += 1
    }
    mutating func record(_ utterance: VoiceUtterance, live: Bool) {
        guard utterance.liveVoice?.live == true, utterance.priority != .sample, live else { return }
        spoken += 1
        if utterance.roadName != nil, utterance.speechVariant != .numberOnly, utterance.speechVariant != .nameFree { named += 1 }
    }
    mutating func skip(_ utterance: VoiceUtterance, reason: String) {
        guard utterance.liveVoice?.live == true, utterance.priority != .sample else { return }
        skipped[reason, default: 0] += 1
    }
}
