@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import FerrostarCore

/// All audio objects, decoded buffers and queue state are confined to `queue`.
/// No route, instruction, or position is retained after its utterance drains.
final class VoicePromptPlayer: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    static let shared = VoicePromptPlayer()
    private static let log = Logger(subsystem: "io.vws.app.flckd", category: "voice")
    private let queue = DispatchQueue(label: "app.flckd.voice", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private var prompts = VoicePromptQueue()
    private var active: VoiceUtterance?
    private var generation = 0
    private var cache: [String: [Float]] = [:]
    private var sessionActive = false
    private var fallbackToken: (utterance: ObjectIdentifier, generation: Int)?
    private var context = VoicePlaybackContext()
    private var cameraEligibility = CameraSpeechEligibility()
    private let sampleRate = 44_100.0

    private override init() {
        super.init()
        engine.attach(node)
        synth.delegate = self
        synth.usesApplicationAudioSession = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.stopAll()
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            self?.stopAll()
        }
    }

    func enqueue(_ utterance: VoiceUtterance) {
        queue.async {
            guard VoiceSettings.fromDefaults().allows(utterance, context: self.context) else { return }
            guard self.cameraEligibility.allows(utterance) else { return }
            if utterance.kind == .preview {
                self.prompts.remove(.sample)
                if self.active?.kind == .preview {
                    self.stopCurrent()
                    self.releaseSession()
                }
            }
            self.prompts.enqueue(utterance)
            self.playNext()
        }
    }

    func updateContext(_ context: VoicePlaybackContext) {
        queue.async {
            self.context = context
            self.applyPermissions()
        }
    }

    func settingsDidChange() {
        queue.async { self.applyPermissions() }
    }

    func updateCameraEligibility(_ eligibility: CameraSpeechEligibility) {
        queue.async {
            self.cameraEligibility = eligibility
            self.prompts.removeInvalidCameras(eligibility)
            self.playNext()
        }
    }

    private func applyPermissions() {
        let settings = VoiceSettings.fromDefaults()
        prompts.removeDisallowed(settings: settings, context: context)
        if let active, !settings.allows(active, context: context) {
            stopCurrent()
            releaseSession()
        }
        playNext()
    }

    func cancel(_ priority: VoiceUtterance.Priority) {
        queue.async {
            self.prompts.remove(priority)
            if self.active?.priority == priority {
                self.stopCurrent()
                self.playNext()
            }
        }
    }

    func stopAll() {
        queue.async {
            self.prompts.clear()
            self.stopCurrent()
            self.releaseSession()
        }
    }

    private func stopCurrent() {
        generation += 1
        active = nil
        fallbackToken = nil
        node.stop()
        synth.stopSpeaking(at: .immediate)
        engine.stop()
    }

    private func playNext() {
        guard active == nil else { return }
        prompts.removeDisallowed(settings: .fromDefaults(), context: context)
        prompts.removeInvalidCameras(cameraEligibility)
        guard let utterance = prompts.next(now: ProcessInfo.processInfo.systemUptime) else {
            releaseSession()
            return
        }
        active = utterance
        generation += 1
        let token = generation
        do {
            try activateSession()
            let clips = try utterance.clips.map { try decoded($0, voice: utterance.voice) }
            guard !clips.isEmpty, clips.allSatisfy({ !$0.isEmpty }),
                  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw PlaybackError.missingClip
            }
            let samples = VoicePCM.compose(clips, sampleRate: sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { throw PlaybackError.missingClip }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: source.count) }
            }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            // One scheduled PCM buffer contains the entire utterance, including
            // joins. Completion is used only to release focus / start another.
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { [weak self] in self?.finished(token: token) }
            }
            node.play()
        } catch {
            engine.stop()
            node.stop()
            if !utterance.fallbackText.isEmpty {
                speakFallback(utterance)
            } else {
                Self.log.error("Recorded prompt could not play")
                finished(token: token)
            }
        }
    }

    private func decoded(_ key: String, voice: PromptVoice) throws -> [Float] {
        let cacheKey = "\(voice.rawValue)/\(key)"
        if let samples = cache[cacheKey] { return samples }
        guard let url = voice.url(for: key) else { throw PlaybackError.missingClip }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PlaybackError.invalidFormat
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw PlaybackError.invalidFormat }
        // AVAudioFile honours AAC edit lists. Trim residual encoder padding and
        // source silence too, so it cannot lengthen the explicitly inserted gap.
        let samples = VoicePCM.trimmed(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        cache[cacheKey] = samples
        return samples
    }

    private func speakFallback(_ prompt: VoiceUtterance) {
        do { try activateSession() } catch {
            Self.log.error("Audio session unavailable for fallback")
            finished(token: generation)
            return
        }
        let utterance = AVSpeechUtterance(string: prompt.fallbackText)
        let language = prompt.language.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased() == language || $0.language.prefix(2).lowercased() == language.prefix(2)
        }
        utterance.voice = voices.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: prompt.language)
        fallbackToken = (ObjectIdentifier(utterance), generation)
        synth.speak(utterance)
    }

    private func activateSession() throws {
        guard !sessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try session.setActive(true)
        sessionActive = true
    }

    private func releaseSession() {
        engine.stop()
        guard sessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        } catch {
            Self.log.error("Audio focus could not be released")
        }
    }

    private func finished(token: Int) {
        guard generation == token, active != nil else { return }
        active = nil
        fallbackToken = nil
        node.stop()
        engine.stop()
        releaseSession()
        playNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        queue.async {
            guard let token = self.fallbackToken, token.utterance == id else { return }
            self.finished(token: token.generation)
        }
    }

    private enum PlaybackError: Error { case missingClip, invalidFormat }
}

/// Ferrostar still needs an observer, but it never speaks or takes audio focus.
struct SilentNavigationSynthesizer: SpeechSynthesizer {
    var isSpeaking: Bool { false }
    func speak(_ utterance: AVSpeechUtterance) {}
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
}
