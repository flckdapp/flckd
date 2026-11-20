import Foundation

enum VoiceRenderPolicy {
    /// Less than one location tick, and only 3% of a camera's five-second TTL.
    static let deadline: TimeInterval = 0.150
    static let utteranceLimit: TimeInterval = 5
    static let nameExtensionLimit: TimeInterval = 2.5
    static let cacheByteLimit = 8 * 1_024 * 1_024
    static let cameraPlaybackReserve: TimeInterval = 0.050

    static func canResolveLive(_ utterance: VoiceUtterance, now: TimeInterval) -> Bool {
        utterance.priority != .camera || VoicePromptQueue.cameraLifetime - (now - utterance.createdAt) > deadline + cameraPlaybackReserve
    }

    enum State: Equatable { case ready, pending, failed }
    enum Decision: Equatable { case live, wait, recorded }

    static func decide(liveVoice: Bool, state: State, elapsed: TimeInterval,
                       thermal: ProcessInfo.ThermalState) -> Decision {
        guard liveVoice, thermal != .serious, thermal != .critical else { return .recorded }
        if elapsed > deadline { return .recorded }
        if state == .ready { return .live }
        if state == .failed || elapsed >= deadline { return .recorded }
        return .wait
    }

    static func fits(audio: Double, recorded: Double, named: Bool) -> Bool {
        audio > 0 && audio <= utteranceLimit && (!named || audio <= recorded + nameExtensionLimit)
    }
}

struct BackgroundSpeechBreaker: Equatable {
    static let threshold = 3
    private(set) var failures = 0
    private(set) var foreground = true
    private(set) var activation = 0
    var allowsRender: Bool { foreground || failures < Self.threshold }

    mutating func setForeground(_ value: Bool) {
        foreground = value
        if value { failures = 0; activation += 1 }
    }

    mutating func record(success: Bool, deadlineMiss: Bool) {
        guard !foreground, failures < Self.threshold else { return }
        if success && !deadlineMiss { failures = 0 }
        else { failures = min(Self.threshold, failures + 1) }
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

    mutating func insert(_ pcm: [Float], for key: SpeechKey, protecting protected: Set<SpeechKey> = []) {
        remove(key)
        let cost = pcm.count * MemoryLayout<Float>.stride
        guard cost <= limit else { return }
        while bytes + cost > limit {
            guard let oldest = order.first(where: { !protected.contains($0) }) else { return }
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
    mutating func record(_ utterance: VoiceUtterance, live: Bool) {
        guard utterance.liveVoice?.live == true, utterance.priority != .sample,
              !(utterance.clips.first?.hasPrefix("arrive") ?? false) else { return }
        requested += 1
        if live { spoken += 1; if utterance.roadName != nil { named += 1 } }
    }
}
