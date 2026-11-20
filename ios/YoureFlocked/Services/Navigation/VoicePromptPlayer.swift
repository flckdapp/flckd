@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import FerrostarCore

/// Audio objects and queue state are main-actor confined. Core ML never runs
/// here; the speech service returns bounded, already-rendered whole utterances.
@MainActor
final class VoicePromptPlayer: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    static let shared = VoicePromptPlayer()
    private static let log = Logger(subsystem: "io.vws.app.flckd", category: "voice")
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
    private var speechStatistics = SpeechStats()
    private var renderTask: Task<Void, Never>?
    private let sampleRate = 44_100.0
    #if DEBUG
    var debugNow: (() -> TimeInterval)?
    var debugResolve: ((VoiceUtterance, Double) async -> PhononSpeechService.Resolution)?
    var debugPlayback: ((VoiceUtterance, Bool) -> Void)?
    func debugFinishCurrent() { finished(token: generation) }
    #endif
    private var now: TimeInterval {
        #if DEBUG
        if let debugNow { return debugNow() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    override init() {
        super.init()
        engine.attach(node)
        synth.delegate = self
        synth.usesApplicationAudioSession = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.stopAll() }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in self?.stopAll() }
        }
    }

    func enqueue(_ incoming: VoiceUtterance) {
        var utterance = incoming
        if utterance.renderedPCM == nil { utterance.renderedPCM = PhononSpeechService.shared.arrivalAudio(utterance) }
        guard VoiceSettings.fromDefaults().allows(utterance, context: context), cameraEligibility.allows(utterance) else { return }
        if utterance.kind == .preview {
            prompts.remove(.sample)
            if active?.kind == .preview { stopCurrent(); releaseSession() }
        }
        prompts.enqueue(utterance)
        playNext()
    }

    func updateContext(_ value: VoicePlaybackContext) { context = value; applyPermissions() }
    func settingsDidChange() { applyPermissions() }
    func updateCameraEligibility(_ value: CameraSpeechEligibility) {
        cameraEligibility = value
        prompts.removeInvalidCameras(value)
        playNext()
    }

    private func applyPermissions() {
        let settings = VoiceSettings.fromDefaults()
        prompts.removeDisallowed(settings: settings, context: context)
        if let active, !settings.allows(active, context: context) { stopCurrent(); releaseSession() }
        playNext()
    }

    func cancel(_ priority: VoiceUtterance.Priority) {
        prompts.remove(priority)
        if active?.priority == priority { stopCurrent(); releaseSession(); playNext() }
    }

    func stopAll() { prompts.clear(); stopCurrent(); releaseSession() }

    private func stopCurrent() {
        generation += 1
        renderTask?.cancel(); renderTask = nil
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
        guard let utterance = prompts.next(now: now) else {
            releaseSession()
            return
        }
        active = utterance
        generation += 1
        let token = generation
        renderTask = Task { [weak self] in
            guard let self else { return }
            var resolved = utterance
            var playedLive = utterance.renderedPCM != nil && utterance.liveVoice?.live == true
            if resolved.renderedPCM == nil, resolved.liveVoice?.live == true,
               VoiceRenderPolicy.canResolveLive(resolved, now: now) {
                let recorded = (try? resolved.clips.map { key -> [Float] in
                    guard let url = resolved.voice.url(for: key) else { throw PlaybackError.missingClip }
                    return try decoded(cacheKey: "\(resolved.voice.rawValue)/\(key)", url: url)
                }) ?? []
                let duration = VoiceClipLoader.duration(recorded, sampleRate: sampleRate)
                let result: PhononSpeechService.Resolution
                #if DEBUG
                if let debugResolve { result = await debugResolve(resolved, duration) }
                else { result = await PhononSpeechService.shared.resolve(resolved, recordedDuration: duration) }
                #else
                result = await PhononSpeechService.shared.resolve(resolved, recordedDuration: duration)
                #endif
                resolved.renderedPCM = result.samples
                playedLive = result.samples != nil
            }
            guard !Task.isCancelled, generation == token, active != nil,
                  VoiceSettings.fromDefaults().allows(resolved, context: context), cameraEligibility.allows(resolved),
                  resolved.priority != .camera || now - resolved.createdAt <= VoicePromptQueue.cameraLifetime else {
                if generation == token { finished(token: token) }
                return
            }
            playResolved(resolved, token: token, playedLive: playedLive)
        }
    }

    private func playResolved(_ utterance: VoiceUtterance, token: Int, playedLive: Bool) {
        #if DEBUG
        if let debugPlayback { debugPlayback(utterance, playedLive); return }
        #endif
        do {
            try activateSession()
            let clips = try loader.samples(for: utterance)
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
                Task { @MainActor [weak self] in self?.finished(token: token) }
            }
            node.play()
            speechStatistics.record(utterance, live: playedLive)
            #if DEBUG
            VoicePlaybackDiagnostics.record(live: playedLive, fallback: utterance.liveVoice?.live == true && !playedLive)
            #endif
        } catch {
            engine.stop()
            node.stop()
            if !utterance.fallbackText.isEmpty {
                speechStatistics.record(utterance, live: false)
                speakFallback(utterance)
            } else {
                Self.log.error("Recorded prompt could not play")
                finished(token: token)
            }
        }
    }

    private var loader: VoiceClipLoader {
        VoiceClipLoader(decode: { [unowned self] cacheKey, url in try self.decoded(cacheKey: cacheKey, url: url) })
    }

    func resetSpeechStats() { speechStatistics = SpeechStats() }
    func speechStats() -> SpeechStats { speechStatistics }

    private func decoded(cacheKey: String, url: URL) throws -> [Float] {
        if let samples = cache[cacheKey] { return samples }
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
        #if DEBUG
        Self.log.debug("on-device speech fallback for an utterance of \(prompt.clips.count) clips")
        #endif
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
        guard let token = fallbackToken, token.utterance == ObjectIdentifier(utterance) else { return }
        finished(token: token.generation)
    }

    private enum PlaybackError: Error { case missingClip, invalidFormat }
}

/// Ferrostar still needs an observer, but it never speaks or takes audio focus.
struct SilentNavigationSynthesizer: SpeechSynthesizer {
    var isSpeaking: Bool { false }
    func speak(_ utterance: AVSpeechUtterance) {}
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
}
