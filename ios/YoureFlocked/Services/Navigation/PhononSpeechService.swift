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
    private let now: @MainActor () -> TimeInterval
    private let thermal: @MainActor () -> ProcessInfo.ThermalState
    private var cache = SpeechCache()
    private var failed = Set<SpeechKey>()
    private var jobs: [SpeechKey] = []
    private var allowed = Set<SpeechKey>()
    private var common = Set<SpeechKey>()
    private var routeWindow = Set<SpeechKey>()
    private var shorterVariants: [SpeechKey: SpeechKey] = [:]
    private var variantLabels: [SpeechKey: SpeechVariant] = [:]
    private var overlong = Set<SpeechKey>()
    private var predictedOmissions = Set<SpeechKey>()
    private var cameraKeys = Set<SpeechKey>()
    private var cameraCache = SpeechCache()
    private var worker: Task<Void, Never>?
    private var warming: Task<Void, Never>?
    private var openingKey: SpeechKey?
    private var loadFailed = false
    private var generation = 0
    private var windowVersion = 0
    private var breaker = BackgroundSpeechBreaker()
    private var attempt: SpeechAttempt?
    private var missedPlayback: [SpeechKey: Set<UUID>] = [:]
    private(set) var loaded = false
    private var trip = false
    #if DEBUG
    func debugCachedVariant(for utterance: VoiceUtterance) -> SpeechVariant? {
        options(for: utterance).first { option in
            audio(for: option.key).map { VoiceRenderPolicy.fits(audio: Double($0.count) / VoiceResampler.outputRate,
                                                                 priority: utterance.priority) } ?? false
        }?.variant
    }

    var forceFailure = false
    private var diagnosticIDs: [SpeechKey: UUID] = [:]
    private var diagnosticKinds: [SpeechKey: SpeechDiagnosticEvent.Kind] = [:]
    private var diagnosticRenders: [SpeechKey: (start: TimeInterval, end: TimeInterval?, audio: Double?)] = [:]

    func diagnose(_ utterance: VoiceUtterance, stage: SpeechDiagnosticEvent.Stage, reason: String? = nil,
                  wait: Double? = nil, cacheHit: Bool? = nil) {
        guard utterance.liveVoice?.live == true, utterance.priority != .sample else { return }
        let key = options(for: utterance).first { $0.variant == (utterance.speechVariant ?? .full) }?.key
        let render = key.flatMap { diagnosticRenders[$0] }
        RoutingMetricsStore.shared.recordSpeechEvent(.init(promptID: utterance.playbackID,
            renderID: key.flatMap { diagnosticIDs[$0] }, kind: SpeechDiagnosticEvent.kind(utterance), stage: stage,
            requestedAt: utterance.createdAt > 0 ? utterance.createdAt : nil,
            renderStart: render?.start, renderEnd: render?.end, waitSeconds: wait,
            audioSeconds: render?.audio, cacheHit: cacheHit, reason: reason, breaker: breaker,
            variant: utterance.speechVariant))
    }

    private func diagnoseRender(_ key: SpeechKey, stage: SpeechDiagnosticEvent.Stage, reason: String? = nil) {
        let id = diagnosticIDs[key] ?? UUID()
        diagnosticIDs[key] = id
        let render = diagnosticRenders[key]
        var event = SpeechDiagnosticEvent(promptID: id, renderID: id,
            kind: diagnosticKinds[key] ?? .guidance, stage: stage, renderStart: render?.start,
            renderEnd: render?.end, audioSeconds: render?.audio, reason: reason, breaker: breaker,
            variant: variantLabels[key])
        event.characters = key.sentences.joined(separator: " ").count
        event.words = key.sentences.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        event.predictedSeconds = SpeechLengthPrediction.seconds(key.sentences)
        RoutingMetricsStore.shared.recordSpeechEvent(event)
    }
    #endif

    init(engine: any SpeechSynthesizing = PhononSynthesizer(),
         applicationActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         automaticWanted: @escaping @MainActor () -> Bool = {
             SpeechWarmUpPolicy.automatic(voice: .selected(), master: VoiceSettings.fromDefaults().master, foreground: true)
         }, now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         thermal: @escaping @MainActor () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        self.engine = engine
        self.applicationActive = applicationActive
        self.automaticWanted = automaticWanted
        self.now = now
        self.thermal = thermal
    }

    func setForeground(_ foreground: Bool) {
        breaker.setForeground(foreground)
        #if DEBUG
        RoutingMetricsStore.shared.recordSpeechEvent(.init(promptID: UUID(), kind: .guidance, stage: .lifecycle, breaker: breaker))
        #endif
        if foreground { missedPlayback.removeAll() }
        SpeechLoadAuthorization.shared.transition(active: foreground && applicationActive())
        if foreground { failed.removeAll(); warmUp(); startWorker() }
        else if !loaded { warming?.cancel() }
    }

    func warmUp(explicitPreview: Bool = false) {
        guard explicitPreview || automaticWanted() else {
            warming?.cancel()
            SpeechLoadAuthorization.shared.transition(active: false)
            return
        }
        guard breaker.foreground, applicationActive(), !loaded, warming == nil else { return }
        loadFailed = false
        warming = Task(priority: .userInitiated) {
            guard !Task.isCancelled, breaker.foreground, applicationActive(), explicitPreview || automaticWanted() else { warming = nil; return }
            do { _ = try await engine.load(); try Task.checkCancellation(); loaded = true }
            catch { loaded = false; loadFailed = true }
            warming = nil
            startWorker()
        }
    }

    func beginTrip(opening: VoiceUtterance? = nil) {
        generation += 1
        trip = true
        cache.clear(); jobs.removeAll(); failed.removeAll(); allowed.removeAll(); common.removeAll()
        cameraCache.clear(); cameraKeys.removeAll(); predictedOmissions.removeAll()
        routeWindow.removeAll()
        shorterVariants.removeAll(); variantLabels.removeAll(); overlong.removeAll()
        missedPlayback.removeAll()
        #if DEBUG
        diagnosticIDs.removeAll(); diagnosticKinds.removeAll(); diagnosticRenders.removeAll()
        if let opening, let key = key(for: opening) { diagnosticKinds[key] = .opening }
        #endif
        openingKey = opening.flatMap(key(for:))
        if let openingKey { common.insert(openingKey); request(openingKey, urgent: true) }
        guard automaticWanted() else { return }
        warmUp()
        // These are finite, generic and reused across trips/steps. No route text.
        let keys = ["depart", "arrive", "rerouting", "new_route", "turn_left", "turn_right", "continue"]
            + CameraVoiceType.allCases.map { "cam.\($0.rawValue).ahead" }
            + Array(CameraPromptSelector.allKeys).sorted()
        for clip in keys {
            let utterance = VoiceUtterance(clips: [clip], priority: clip.hasPrefix("cam.") ? .camera : .guidance, createdAt: 0, liveVoice: .selected())
            if let key = key(for: utterance) {
                if utterance.priority == .camera { cameraKeys.insert(key) }
                #if DEBUG
                diagnosticKinds[key] = SpeechDiagnosticEvent.kind(utterance)
                #endif
                common.insert(key); request(key)
            }
        }
    }

    func endTrip() {
        generation += 1
        trip = false
        openingKey = nil
        worker?.cancel()
        cache.clear(); jobs.removeAll(); failed.removeAll(); allowed.removeAll(); common.removeAll()
        cameraCache.clear(); cameraKeys.removeAll(); predictedOmissions.removeAll()
        routeWindow.removeAll()
        shorterVariants.removeAll(); variantLabels.removeAll(); overlong.removeAll()
        missedPlayback.removeAll()
        #if DEBUG
        diagnosticIDs.removeAll(); diagnosticKinds.removeAll(); diagnosticRenders.removeAll()
        #endif
        // Keep the warmed model: loading again while locked is forbidden.
        // PCM and all route text are gone; the model itself carries no trip.
    }

    func plan(_ utterances: [VoiceUtterance]) {
        windowVersion += 1
        let keys = utterances.compactMap { preferredKey(for: $0) }
        let variants = utterances.flatMap(options(for:)).map(\.key)
        routeWindow = Set(variants)
        allowed = routeWindow.union(common)
        overlong.formIntersection(allowed)
        predictedOmissions.formIntersection(allowed)
        shorterVariants = shorterVariants.filter { allowed.contains($0.key) && allowed.contains($0.value) }
        variantLabels = variantLabels.filter { allowed.contains($0.key) }
        cache.retain(allowed)
        failed.formIntersection(allowed)
        missedPlayback = missedPlayback.filter { allowed.contains($0.key) }
        jobs.removeAll { !allowed.contains($0) }
        #if DEBUG
        diagnosticIDs = diagnosticIDs.filter { allowed.contains($0.key) }
        diagnosticKinds = diagnosticKinds.filter { allowed.contains($0.key) }
        diagnosticRenders = diagnosticRenders.filter { allowed.contains($0.key) }
        for utterance in utterances {
            for option in options(for: utterance) {
                if diagnosticIDs[option.key] == nil { diagnosticIDs[option.key] = UUID() }
                diagnosticKinds[option.key] = SpeechDiagnosticEvent.kind(utterance)
            }
            diagnose(utterance, stage: .scheduled)
        }
        #endif
        // Queue the whole batch before starting; otherwise the reversed batch
        // could start its farthest step while the nearest is still being added.
        var seen = Set<SpeechKey>()
        let pending = keys.filter { $0 != attempt?.key && audio(for: $0) == nil && !overlong.contains($0) && !failed.contains($0) && seen.insert($0).inserted }
        jobs = pending + jobs.filter { !seen.contains($0) }
        utterances.forEach(registerVariants)
        prioritizeOpening()
        startWorker()
    }

    private func key(for utterance: VoiceUtterance) -> SpeechKey? {
        guard let voice = utterance.liveVoice, voice.live, let sentences = PromptSpeech.sentences(utterance), !sentences.isEmpty else { return nil }
        return SpeechKey(voice: voice, sentences: sentences)
    }

    private func options(for utterance: VoiceUtterance) -> [(variant: SpeechVariant, key: SpeechKey)] {
        guard let voice = utterance.liveVoice, voice.live else { return [] }
        return PromptSpeech.variants(utterance).map { ($0.variant, SpeechKey(voice: voice, sentences: $0.sentences)) }
    }

    private func audio(for key: SpeechKey) -> [Float]? { cameraCache.audio[key] ?? cache.audio[key] }

    private func preferredKey(for utterance: VoiceUtterance) -> SpeechKey? {
        let variants = PromptSpeech.variants(utterance)
        let options = options(for: utterance)
        guard !options.isEmpty else { return nil }
        let index = SpeechLengthPrediction.preferred(variants)
        for option in options.prefix(index) { predictedOmissions.insert(option.key) }
        return options[index].key
    }

    private func registerVariants(_ utterance: VoiceUtterance) {
        let options = options(for: utterance)
        for option in options { variantLabels[option.key] = option.variant }
        for (a, b) in zip(options, options.dropFirst()) { shorterVariants[a.key] = b.key }
        // A full render can already be cached when a new window is registered.
        for option in options {
            if overlong.contains(option.key), let next = shorterVariants[option.key] { request(next, urgent: true) }
        }
    }

    private func request(_ key: SpeechKey, urgent: Bool = false) {
        guard attempt?.key != key, audio(for: key) == nil, !overlong.contains(key), !failed.contains(key), allowed.contains(key) || common.contains(key) else { return }
        #if DEBUG
        if diagnosticIDs[key] == nil { diagnosticIDs[key] = UUID() }
        #endif
        if urgent { jobs.removeAll { $0 == key }; jobs.insert(key, at: 0) }
        else if !jobs.contains(key) { jobs.append(key) }
        prioritizeOpening()
        startWorker()
    }

    private func prioritizeOpening() {
        let arrivals = Set(common.filter { $0.sentences == [PromptText.sentence(for: "arrive") ?? ""] })
        if let index = jobs.firstIndex(where: { arrivals.contains($0) }) {
            let key = jobs.remove(at: index); jobs.insert(key, at: 0)
        }
        if let openingKey, let index = jobs.firstIndex(of: openingKey) { jobs.remove(at: index); jobs.insert(openingKey, at: 0) }
    }

    private func startWorker() {
        guard worker == nil, loaded, breaker.canAttempt(now: now()), thermal() != .critical else { return }
        worker = Task(priority: .userInitiated) {
            while !Task.isCancelled, !jobs.isEmpty, breaker.canAttempt(now: now()) {
                guard thermal() != .critical else { break }
                let key = jobs.removeFirst()
                guard audio(for: key) == nil, !overlong.contains(key), !failed.contains(key), allowed.contains(key) || common.contains(key) else { continue }
                guard breaker.beginAttempt(now: now()) else { jobs.insert(key, at: 0); break }
                let probe = breaker.probing
                let token = generation
                let window = windowVersion
                let background = !breaker.foreground
                let activation = breaker.activation
                attempt = SpeechAttempt(key: key, generation: token, window: window, background: background, activation: activation)
                let start = ProcessInfo.processInfo.systemUptime
                #if DEBUG
                let renderID = diagnosticIDs[key] ?? UUID()
                let renderKind = diagnosticKinds[key] ?? .guidance
                diagnosticIDs[key] = renderID
                diagnosticRenders[key] = (start, nil, nil)
                diagnoseRender(key, stage: .renderStart)
                #endif
                do {
                    let result = try await engine.render(key.sentences.joined(separator: " "), voice: key.voice.name)
                    #if DEBUG
                    let end = ProcessInfo.processInfo.systemUptime
                    let seconds = Double(result.samples.count) / VoiceResampler.outputRate
                    RoutingMetricsStore.shared.recordSpeechEvent(.init(promptID: renderID, renderID: renderID,
                        kind: renderKind, stage: .renderEnd, renderStart: start, renderEnd: end, audioSeconds: seconds,
                        reason: token == generation && allowed.contains(key) ? nil : "renderDiscarded", breaker: breaker,
                        variant: variantLabels[key]))
                    if token == generation, allowed.contains(key) { diagnosticRenders[key] = (start, end, seconds) }
                    #endif
                    guard var completed = attempt else { continue }
                    attempt = nil
                    let playbackMissed = missedPlayback.removeValue(forKey: key)?.isEmpty == false
                    guard !Task.isCancelled, completed.isEligible(generation: generation, window: windowVersion, allowed: allowed, common: common) else {
                        if probe, activation == breaker.activation { breaker.completeProbe(success: false, now: now()) }
                        continue
                    }
                    if allowed.contains(key) {
                        if Double(result.samples.count) / VoiceResampler.outputRate > VoiceRenderPolicy.utteranceLimit {
                            // Keep only the duration verdict, not unusable PCM
                            // that could crowd the shorter variant out of cache.
                            overlong.insert(key)
                            if let next = shorterVariants[key] { request(next, urgent: true) }
                        } else if cameraKeys.contains(key) { cameraCache.insert(result.samples, for: key, protecting: cameraKeys) }
                        else { cache.insert(result.samples, for: key, protecting: routeWindow) }
                    }
                    if probe, activation == breaker.activation { breaker.completeProbe(success: true, now: now()) }
                    else if !playbackMissed { completed.account(success: true, deadlineMiss: false, breaker: &breaker) }
                    if openingKey == key { openingKey = nil }
                    #if DEBUG
                    RoutingMetricsStore.shared.recordSpeechRender(wall: ProcessInfo.processInfo.systemUptime - start,
                        background: background, success: true, errorType: nil, deadlineMiss: playbackMissed)
                    #endif
                } catch {
                    #if DEBUG
                    let end = ProcessInfo.processInfo.systemUptime
                    RoutingMetricsStore.shared.recordSpeechEvent(.init(promptID: renderID, renderID: renderID,
                        kind: renderKind, stage: .renderEnd, renderStart: start, renderEnd: end,
                        reason: "renderFailed", breaker: breaker, variant: variantLabels[key]))
                    if token == generation, allowed.contains(key) { diagnosticRenders[key] = (start, end, nil) }
                    #endif
                    guard var completed = attempt else { continue }
                    attempt = nil
                    let playbackMissed = missedPlayback.removeValue(forKey: key)?.isEmpty == false
                    guard !Task.isCancelled, completed.isEligible(generation: generation, window: windowVersion, allowed: allowed, common: common) else {
                        if probe, activation == breaker.activation { breaker.completeProbe(success: false, now: now()) }
                        continue
                    }
                    failed.insert(key)
                    if probe, activation == breaker.activation { breaker.completeProbe(success: false, now: now()) }
                    else if !playbackMissed { completed.account(success: false, deadlineMiss: false, breaker: &breaker) }
                    if openingKey == key { openingKey = nil }
                    #if DEBUG
                    RoutingMetricsStore.shared.recordSpeechRender(wall: ProcessInfo.processInfo.systemUptime - start,
                        background: background, success: false, errorType: String(describing: type(of: error)), deadlineMiss: playbackMissed)
                    #endif
                }
            }
            worker = nil
            if !jobs.isEmpty, breaker.canAttempt(now: now()), thermal() != .critical { startWorker() }
        }
    }

    struct Resolution {
        let samples: [Float]?
        let reason: String?
        var variant: SpeechVariant? = nil
    }

    /// Capture generic arrival audio before trip teardown clears every cache.
    func arrivalAudio(_ utterance: VoiceUtterance) -> [Float]? {
        guard utterance.clips.first?.hasPrefix("arrive") == true,
              thermal() != .critical,
              let key = key(for: utterance), let pcm = cache.audio[key],
              Double(pcm.count) / VoiceResampler.outputRate <= VoiceRenderPolicy.utteranceLimit else { return nil }
        return pcm
    }

    func resolve(_ utterance: VoiceUtterance) async -> Resolution {
        #if DEBUG
        let waitStart = ProcessInfo.processInfo.systemUptime
        diagnose(utterance, stage: .resolving)
        #endif
        func result(_ samples: [Float]? = nil, _ reason: String? = nil, cacheHit: Bool = false,
                    variant: SpeechVariant? = nil) -> Resolution {
            #if DEBUG
            var diagnosed = utterance
            diagnosed.speechVariant = variant
            diagnose(diagnosed, stage: .resolved, reason: reason,
                     wait: ProcessInfo.processInfo.systemUptime - waitStart, cacheHit: cacheHit)
            #endif
            return Resolution(samples: samples, reason: reason, variant: variant)
        }
        guard utterance.liveVoice?.live == true else { return Resolution(samples: nil, reason: nil) }
        guard thermal() != .critical else { return result(nil, "thermalCritical") }
        guard let key = key(for: utterance) else { return result(nil, "textGate") }
        #if DEBUG
        if forceFailure || ProcessInfo.processInfo.arguments.contains("-forceSpeechFailure") { return result(nil, "forcedFailure") }
        #endif
        let token = generation
        var playback = SpeechPlaybackRequest(key: key, generation: token)
        let oneShot = !trip
        let options = options(for: utterance)
        let optionKeys = Set(options.map(\.key))
        allowed.formUnion(optionKeys)
        let preferred = preferredKey(for: utterance) ?? key
        registerVariants(utterance)
        #if DEBUG
        diagnosticKinds[key] = SpeechDiagnosticEvent.kind(utterance)
        #endif
        defer {
            if oneShot {
                allowed.subtract(optionKeys); jobs.removeAll { optionKeys.contains($0) }; cache.retain(allowed)
                failed.subtract(optionKeys)
                overlong.subtract(optionKeys)
                shorterVariants = shorterVariants.filter { !optionKeys.contains($0.key) }
                variantLabels = variantLabels.filter { !optionKeys.contains($0.key) }
            }
        }
        // Foreground-only loading is independent of navigation startup. Opening
        // waits for it, but neither the location pipeline nor UI waits for us.
        if !loaded {
            guard breaker.foreground, applicationActive() else { return result(nil, "backgroundUnloaded") }
            warmUp()
        }
        if breaker.canAttempt(now: now()) { failed.remove(preferred); request(preferred, urgent: true) }
        while !Task.isCancelled, token == generation {
            let remaining = VoiceRenderPolicy.remaining(utterance, now: now())
            guard remaining > 0 else {
                if playback.generation == generation, allowed.contains(key), playback.deadline(breaker: &breaker, now: now()) {
                    missedPlayback[key, default: []].insert(playback.id)
                }
                return result(nil, utterance.isOpening ? "openingDeadline" : utterance.priority == .camera ? "cameraExpired" : "guidanceDeadline")
            }
            guard thermal() != .critical else { return result(nil, "thermalCritical") }
            var waitingKey = key
            for option in options {
                waitingKey = option.key
                if predictedOmissions.contains(option.key), audio(for: option.key) == nil { continue }
                if overlong.contains(option.key) {
                    if option.key == options.last?.key { return result(nil, "duration", variant: option.variant) }
                    continue
                }
                guard let pcm = audio(for: option.key) else {
                    request(option.key, urgent: true)
                    break
                }
                if VoiceRenderPolicy.fits(audio: Double(pcm.count) / VoiceResampler.outputRate, priority: utterance.priority) {
                    return result(pcm, cacheHit: true, variant: option.variant)
                }
                if option.key == options.last?.key { return result(nil, "duration", cacheHit: true, variant: option.variant) }
            }
            if failed.contains(waitingKey) { return result(nil, "renderFailed") }
            if loadFailed, warming == nil, !loaded { return result(nil, "loadFailed") }
            if !loaded, !breaker.foreground { return result(nil, "backgroundUnloaded") }
            if !breaker.canAttempt(now: now()), !(breaker.probing && optionKeys.contains(attempt?.key ?? key)) { return result(nil, "breaker") }
            if loaded { startWorker() }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        return result(nil, "cancelled")
    }

    #if DEBUG
    func unloadForTesting() async throws {
        endTrip()
        warming?.cancel()
        await warming?.value
        await worker?.value
        if let engine = engine as? PhononSynthesizer { try await engine.unload() }
        loaded = false
        loadFailed = false
    }

    func debugState(for utterance: VoiceUtterance) -> (cached: Bool, failed: Bool, active: Bool, failures: Int, queued: Int) {
        let key = key(for: utterance)
        return (key.flatMap { audio(for: $0) } != nil, key.map(failed.contains) ?? false,
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
        var utterance = VoiceUtterance.preview(voice: voice.recording ?? .male, now: 0)
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
