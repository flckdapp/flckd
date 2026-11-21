#if DEBUG
import Foundation
import UIKit

/// Schema deliberately has no text, clip key, route identity or location field.
/// Render IDs are random, session-local links, not hashes of spoken content.
struct SpeechDiagnosticEvent: Codable {
    enum Kind: String, Codable { case opening, guidance, camera }
    enum Stage: String, Codable {
        case scheduled, requested, renderStart, renderEnd, resolving, resolved, played, completed, skipped, lifecycle
    }
    let recordType: String
    let promptID: UUID
    let renderID: UUID?
    let kind: Kind
    let stage: Stage
    let date: Date
    let uptime: TimeInterval
    let background: Bool
    let applicationState: String
    let requestedAt: TimeInterval?
    let renderStart: TimeInterval?
    let renderEnd: TimeInterval?
    let waitSeconds: Double?
    let audioSeconds: Double?
    let cacheHit: Bool?
    let reason: String?
    let breaker: String
    let breakerFailures: Int
    let variant: SpeechVariant?
    var characters: Int? = nil
    var words: Int? = nil
    var predictedSeconds: Double? = nil

    @MainActor
    init(promptID: UUID, renderID: UUID? = nil, kind: Kind, stage: Stage,
         requestedAt: TimeInterval? = nil, renderStart: TimeInterval? = nil,
         renderEnd: TimeInterval? = nil, waitSeconds: Double? = nil,
         audioSeconds: Double? = nil, cacheHit: Bool? = nil, reason: String? = nil,
         breaker: BackgroundSpeechBreaker, variant: SpeechVariant? = nil,
         now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        recordType = "speechTimeline"
        self.promptID = promptID; self.renderID = renderID; self.kind = kind; self.stage = stage
        date = Date(); uptime = now
        background = !breaker.foreground
        switch UIApplication.shared.applicationState {
        case .active: applicationState = "active"
        case .inactive: applicationState = "inactive"
        case .background: applicationState = "background"
        @unknown default: applicationState = "unknown"
        }
        self.requestedAt = requestedAt; self.renderStart = renderStart; self.renderEnd = renderEnd
        self.waitSeconds = waitSeconds; self.audioSeconds = audioSeconds; self.cacheHit = cacheHit
        // Callers cannot accidentally persist an engine description or spoken text.
        let reasons: Set<String> = ["thermalCritical", "textGate", "forcedFailure", "backgroundUnloaded",
            "openingDeadline", "cameraExpired", "guidanceDeadline", "duration", "renderFailed", "loadFailed",
            "breaker", "cancelled", "superseded", "cameraPriority", "stepChanged", "stopped",
            "staleGuidance", "expiredOrDisallowed", "missingLiveAudio", "playbackError", "disallowed",
            "cameraIneligible", "renderDiscarded"]
        self.reason = reason.map { reasons.contains($0) ? $0 : "other" }
        self.breaker = breaker.probing ? "probe" : breaker.retryAt != nil ? "open" : "closed"
        breakerFailures = breaker.failures
        self.variant = variant
    }

    static func kind(_ utterance: VoiceUtterance) -> Kind {
        utterance.isOpening ? .opening : utterance.priority == .camera ? .camera : .guidance
    }
}
#endif
