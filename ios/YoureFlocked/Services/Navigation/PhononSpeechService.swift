import Foundation
import UIKit

/// Main-actor coordinator; rendering itself runs on Phonon's user-initiated
/// serial queue. A deadline abandons a lookup, never waits for Core ML to stop.
@MainActor
final class PhononSpeechService {
    static let shared = PhononSpeechService()
    private let engine: any SpeechSynthesizing
    private let applicationActive: @MainActor () -> Bool
    private let automaticWanted: @MainActor () -> Bool
    private var cache = SpeechCache()
    private var failed = Set<SpeechKey>()
    private var jobs: [SpeechKey] = []
    private var allowed = Set<SpeechKey>()
    private var common = Set<SpeechKey>()
    private var routeWindow = Set<SpeechKey>()
    private var worker: Task<Void, Never>?
    private var warming: Task<Void, Never>?
    private var generation = 0
    private var windowVersion = 0
    private var breaker = BackgroundSpeechBreaker()
    private var attempt: SpeechAttempt?
    private var missedPlayback: [SpeechKey: Set<UUID>] = [:]
    private(set) var loaded = false
    private var trip = false
    #if DEBUG
    var forceFailure = false
    #endif

    init(engine: any SpeechSynthesizing = PhononSynthesizer(),
         applicationActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         automaticWanted: @escaping @MainActor () -> Bool = {
             SpeechWarmUpPolicy.automatic(voice: .selected(), master: VoiceSettings.fromDefaults().master, foreground: true)
         }) {
        self.engine = engine
        self.applicationActive = applicationActive
        self.automaticWanted = automaticWanted
    }

    func setForeground(_ foreground: Bool) {
        breaker.setForeground(foreground)
        if foreground { missedPlayback.removeAll() }
        SpeechLoadAuthorization.shared.transition(active: foreground && applicationActive())
        if foreground { failed.removeAll(); warmUp(); startWorker() }
        else { warming?.cancel() }
    }

    func warmUp(explicitPreview: Bool = false) {
        guard explicitPreview || automaticWanted() else {
            warming?.cancel()
            SpeechLoadAuthorization.shared.transition(active: false)
            return
        }
        guard breaker.foreground, applicationActive(), !loaded, warming == nil else { return }
        warming = Task(priority: .userInitiated) {
            guard !Task.isCancelled, breaker.foreground, applicationActive(), explicitPreview || automaticWanted() else { warming = nil; return }
            do { _ = try await engine.load(); try Task.checkCancellation(); loaded = true }
            catch { loaded = false }
            warming = nil
            startWorker()
        }
    }

    func beginTrip() {
        generation += 1
        trip = true
        cache.clear(); jobs.removeAll(); failed.removeAll(); allowed.removeAll(); common.removeAll()
        routeWindow.removeAll()
        missedPlayback.removeAll()
        guard automaticWanted() else { return }
        warmUp()
        // These are finite, generic and reused across trips/steps. No route text.
        let keys = ["depart", "arrive", "rerouting", "new_route", "turn_left", "turn_right", "continue"]
            + CameraVoiceType.allCases.map { "cam.\($0.rawValue).ahead" }
            + Array(CameraPromptSelector.allKeys).sorted()
        for clip in keys {
            let utterance = VoiceUtterance(clips: [clip], createdAt: 0, liveVoice: .selected())
            if let key = key(for: utterance) { common.insert(key); request(key) }
        }
    }

    func endTrip() {
        generation += 1
        trip = false
        worker?.cancel()
        cache.clear(); jobs.removeAll(); failed.removeAll(); allowed.removeAll(); common.removeAll()
        routeWindow.removeAll()
        missedPlayback.removeAll()
        // Keep the warmed model: loading again while locked is forbidden.
        // PCM and all route text are gone; the model itself carries no trip.
    }

    func plan(_ utterances: [VoiceUtterance]) {
        windowVersion += 1
        let keys = utterances.compactMap(key(for:))
        routeWindow = Set(keys)
        allowed = Set(keys).union(common)
        cache.retain(allowed)
        failed.formIntersection(allowed)
        missedPlayback = missedPlayback.filter { allowed.contains($0.key) }
        jobs.removeAll { !allowed.contains($0) }
        // Queue the whole batch before starting; otherwise the reversed batch
        // could start its farthest step while the nearest is still being added.
        var seen = Set<SpeechKey>()
        let pending = keys.filter { $0 != attempt?.key && cache.audio[$0] == nil && !failed.contains($0) && seen.insert($0).inserted }
        jobs = pending + jobs.filter { !seen.contains($0) }
        startWorker()
    }

    private func key(for utterance: VoiceUtterance) -> SpeechKey? {
        guard let voice = utterance.liveVoice, voice.live, let sentences = PromptSpeech.sentences(utterance), !sentences.isEmpty else { return nil }
        return SpeechKey(voice: voice, sentences: sentences)
    }

    private func request(_ key: SpeechKey, urgent: Bool = false) {
        guard attempt?.key != key, cache.audio[key] == nil, !failed.contains(key), allowed.contains(key) || common.contains(key) else { return }
        if urgent { jobs.removeAll { $0 == key }; jobs.insert(key, at: 0) }
        else if !jobs.contains(key) { jobs.append(key) }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, loaded, breaker.allowsRender,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return }
        worker = Task(priority: .userInitiated) {
            while !Task.isCancelled, !jobs.isEmpty, breaker.allowsRender {
                guard ProcessInfo.processInfo.thermalState != .serious,
                      ProcessInfo.processInfo.thermalState != .critical else { break }
                let key = jobs.removeFirst()
                guard cache.audio[key] == nil, !failed.contains(key), allowed.contains(key) || common.contains(key) else { continue }
                let token = generation
                let window = windowVersion
                let background = !breaker.foreground
                let activation = breaker.activation
                attempt = SpeechAttempt(key: key, generation: token, window: window, background: background, activation: activation)
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let result = try await engine.render(key.sentences.joined(separator: " "), voice: key.voice.name)
                    guard var completed = attempt else { continue }
                    attempt = nil
                    let playbackMissed = missedPlayback.removeValue(forKey: key)?.isEmpty == false
                    guard !Task.isCancelled, completed.isEligible(generation: generation, window: windowVersion, allowed: allowed, common: common) else { continue }
                    if allowed.contains(key) {
                        cache.insert(result.samples, for: key, protecting: routeWindow)
                    }
                    if !playbackMissed { completed.account(success: true, deadlineMiss: false, breaker: &breaker) }
                    #if DEBUG
                    RoutingMetricsStore.shared.recordSpeechRender(wall: ProcessInfo.processInfo.systemUptime - start,
                        background: background, success: true, errorType: nil, deadlineMiss: playbackMissed)
                    #endif
                } catch {
                    guard var completed = attempt else { continue }
                    attempt = nil
                    let playbackMissed = missedPlayback.removeValue(forKey: key)?.isEmpty == false
                    guard !Task.isCancelled, completed.isEligible(generation: generation, window: windowVersion, allowed: allowed, common: common) else { continue }
                    failed.insert(key)
                    if !playbackMissed { completed.account(success: false, deadlineMiss: false, breaker: &breaker) }
                    #if DEBUG
                    RoutingMetricsStore.shared.recordSpeechRender(wall: ProcessInfo.processInfo.systemUptime - start,
                        background: background, success: false, errorType: String(describing: type(of: error)), deadlineMiss: playbackMissed)
                    #endif
                }
            }
            worker = nil
            if !jobs.isEmpty, breaker.allowsRender,
               ProcessInfo.processInfo.thermalState != .serious,
               ProcessInfo.processInfo.thermalState != .critical { startWorker() }
        }
    }

    struct Resolution {
        let samples: [Float]?
        let reason: String?
    }

    /// Capture generic arrival audio before trip teardown clears every cache.
    func arrivalAudio(_ utterance: VoiceUtterance) -> [Float]? {
        guard utterance.clips.first?.hasPrefix("arrive") == true,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              let key = key(for: utterance), let pcm = cache.audio[key],
              Double(pcm.count) / VoiceResampler.outputRate <= VoiceRenderPolicy.utteranceLimit else { return nil }
        return pcm
    }

    func resolve(_ utterance: VoiceUtterance, recordedDuration: Double) async -> Resolution {
        guard utterance.liveVoice?.live == true else { return Resolution(samples: nil, reason: nil) }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else { return fallback("thermal") }
        guard loaded else { return fallback("notLoaded") }
        guard let key = key(for: utterance) else { return fallback("textGate") }
        #if DEBUG
        if forceFailure || ProcessInfo.processInfo.arguments.contains("-forceSpeechFailure") { return fallback("forcedFailure") }
        #endif
        let token = generation
        var playback = SpeechPlaybackRequest(key: key, generation: token)
        let start = ProcessInfo.processInfo.systemUptime
        let oneShot = !trip
        allowed.insert(key)
        defer {
            if oneShot {
                allowed.remove(key)
                jobs.removeAll { $0 == key }
                cache.retain(allowed)
                failed.remove(key)
            }
        }
        if breaker.allowsRender { request(key, urgent: true) }
        while !Task.isCancelled, token == generation {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let state: VoiceRenderPolicy.State = cache.audio[key] != nil ? .ready : failed.contains(key) ? .failed : .pending
            let decision = VoiceRenderPolicy.decide(liveVoice: true, state: state, elapsed: elapsed,
                                                     thermal: ProcessInfo.processInfo.thermalState)
            if decision == .live, let pcm = cache.audio[key] {
                guard VoiceRenderPolicy.fits(audio: Double(pcm.count) / VoiceResampler.outputRate,
                    recorded: recordedDuration, named: utterance.roadName != nil || utterance.exitNumber != nil) else { return fallback("duration") }
                return Resolution(samples: pcm, reason: nil)
            }
            if decision == .recorded || !breaker.allowsRender {
                let miss = state != .failed && elapsed >= VoiceRenderPolicy.deadline
                if miss, playback.generation == generation, allowed.contains(key), playback.deadline(breaker: &breaker) {
                    missedPlayback[key, default: []].insert(playback.id)
                }
                #if DEBUG
                if miss { RoutingMetricsStore.shared.recordSpeechRender(wall: elapsed, background: !breaker.foreground,
                    success: false, errorType: nil, deadlineMiss: true) }
                #endif
                return fallback(!breaker.allowsRender ? "breaker" : state == .failed ? "renderFailed" : "deadline")
            }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        return Resolution(samples: nil, reason: "cancelled")
    }

    private func fallback(_ reason: String) -> Resolution {
        #if DEBUG
        RoutingMetricsStore.shared.recordSpeechFallback(reason)
        #endif
        return Resolution(samples: nil, reason: reason)
    }

    #if DEBUG
    func debugState(for utterance: VoiceUtterance) -> (cached: Bool, failed: Bool, active: Bool, failures: Int, queued: Int) {
        let key = key(for: utterance)
        return (key.flatMap { cache.audio[$0] } != nil, key.map(failed.contains) ?? false,
                key != nil && key == attempt?.key, breaker.failures, jobs.filter { $0 == key }.count)
    }
    #endif

    func preview(_ voice: NavigationVoice) async throws -> [Float] {
        guard breaker.foreground, voice.live else { throw PhononSynthesizer.Failure.missingModels }
        warmUp(explicitPreview: true)
        await warming?.value
        guard breaker.foreground else { throw PhononSynthesizer.Failure.missingModels }
        // Use the same serialized worker; previews have an explicit longer wait,
        // and never substitute a recording without telling Settings.
        var utterance = VoiceUtterance.preview(voice: voice.recorded, now: 0)
        utterance.roadName = "Main Street"
        utterance.liveVoice = voice
        guard let key = key(for: utterance) else { throw PhononSynthesizer.Failure.invalidText }
        defer {
            allowed.remove(key)
            jobs.removeAll { $0 == key }
            cache.retain(allowed)
            failed.remove(key)
        }
        allowed.insert(key); failed.remove(key); request(key, urgent: true)
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 30, !Task.isCancelled {
            if let pcm = cache.audio[key] { return pcm }
            if failed.contains(key) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PhononSynthesizer.Failure.emptyAudio
    }
}
