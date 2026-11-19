@preconcurrency import AVFoundation
import Foundation
import UIKit
@preconcurrency import FerrostarCoreFFI

/// One street-name sentence worth rendering ahead.
struct KokoroNameRequest: Equatable, Sendable {
    let stepOffset: Int
    let firstKey: String
    let name: String
    let text: String
}

/// Which named approach prompts the next three steps can produce. Pure.
enum KokoroNamePlanner {
    struct Step {
        let banner: VisualInstructionContent?
        let distance: Double
        let roundaboutExitNumber: UInt8?
    }

    static func steps(_ routeSteps: [RouteStep]) -> [Step] {
        routeSteps.map { Step(banner: $0.visualInstructions.first?.primaryContent, distance: $0.distance,
                              roundaboutExitNumber: $0.roundaboutExitNumber) }
    }

    /// Current step first; within a step, farthest prompt first. The action and
    /// thresholds come from the same code `speakInstruction` uses.
    static func requests(steps: [Step], units: DistanceUnits, knows: (String) -> Bool) -> [KokoroNameRequest] {
        var requests: [KokoroNameRequest] = []
        for offset in 0..<min(3, steps.count) {
            guard let banner = steps[offset].banner else { continue }
            let exit = offset + 1 < steps.count ? steps[offset + 1].roundaboutExitNumber : nil
            guard let action = GuidancePromptSelector.action(banner, roundaboutExit: exit) else { continue }
            for threshold in GuidancePromptSchedule.approachThresholds(length: steps[offset].distance, units: units) {
                let key = "\(threshold.key).\(action)"
                guard let sentence = SpokenRoadName.sentence(firstKey: key, bannerText: banner.text, knows: knows) else { continue }
                requests.append(KokoroNameRequest(stepOffset: offset, firstKey: key, name: sentence.name, text: sentence.text))
            }
        }
        return requests
    }
}

/// Renders upcoming street names ahead of the prompts that need them, during a
/// trip, while the app is on screen, and keeps the audio in memory only.
///
/// State is guarded by `lock`; renders run one at a time on the synthesizer's
/// queue. `generation` changes when a trip ends, so a render that finishes
/// after that is discarded. A request is rendered at most once per window and
/// can never block the ones behind it. Playback never waits for any of this.
final class KokoroNameRenderer: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let preset: String
        let firstKey: String
        let name: String
    }

    struct Request: Equatable, Sendable {
        let key: Key
        let text: String
        let preset: KokoroPreset
    }

    enum PreviewResult: Equatable, Sendable {
        case rendered(samples: [Float], rtf: Double)
        case cancelled
        case failed
    }

    /// A named first clip may be at most this much longer than the name-free one (plan P5a).
    static let firstClipAllowance: TimeInterval = 1.5

    static let shared = KokoroNameRenderer()

    private let synthesizer: KokoroSynthesizer
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let nameFreeDuration: @Sendable (KokoroPreset, String) -> TimeInterval?
    private let namesEnabled: @Sendable () -> Bool
    private let storeRTF: @Sendable (Double) -> Void
    private var observers: [NSObjectProtocol] = []

    private let lock = NSLock()
    private var generation = 0
    private var window = Set<Key>()
    private var queue: [Request] = []
    private var inFlight: (generation: Int, key: Key)?
    private var attempted = Set<Key>()
    private var cache: [Key: [Float]] = [:]
    private var tripRTFs: [Double] = []
    private var active = false
    private var tripActive = false
    private var tripBlocked = false
    private var engineReady = false
    private var lexicon: KokoroLexicon?
    private var previewToken = 0
    private var planVersion = 0
    private var lastPlan: (steps: [KokoroNamePlanner.Step], units: DistanceUnits, preset: KokoroPreset)?

    static let standardNameFreeDuration: @Sendable (KokoroPreset, String) -> TimeInterval? = { preset, key in
        guard let url = KokoroVoiceStore.standard?.clipURL(preset: preset, key: key),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    init(synthesizer: KokoroSynthesizer = KokoroSynthesizer(),
         thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         nameFreeDuration: @escaping @Sendable (KokoroPreset, String) -> TimeInterval? = KokoroNameRenderer.standardNameFreeDuration,
         namesEnabled: @escaping @Sendable () -> Bool = { KokoroSupport.namesEnabled() },
         storeRTF: @escaping @Sendable (Double) -> Void = { KokoroSupport.storeMeasurement($0) },
         notificationCenter: NotificationCenter = .default) {
        self.synthesizer = synthesizer
        self.thermalState = thermalState
        self.nameFreeDuration = nameFreeDuration
        self.namesEnabled = namesEnabled
        self.storeRTF = storeRTF
        observers.append(notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.kick() })
        observers.append(notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.memoryWarning() })
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Trip

    func beginTrip() {
        let enabled = namesEnabled()
        let current: Int = locked {
            previewToken += 1
            tripActive = true
            tripBlocked = false
            engineReady = false
            lexicon = nil
            attempted.removeAll()
            tripRTFs.removeAll()
            return generation
        }
        guard enabled else { return }
        synthesizer.queue.async { [self] in
            let loaded = synthesizer.loadOnQueue()
            let words = synthesizer.lexicon
            let ready: Bool = locked {
                guard loaded, generation == current, tripActive, !tripBlocked else { return false }
                engineReady = true
                lexicon = words
                return true
            }
            if ready { replan() }
            kick()
        }
    }

    func endTrip() {
        reset(blocking: false)
    }

    /// The name planner's input for the current step; replanned once the word
    /// list has loaded.
    func plan(steps: [KokoroNamePlanner.Step], units: DistanceUnits, preset: KokoroPreset) {
        locked {
            planVersion += 1
            lastPlan = (steps, units, preset)
        }
        replan()
    }

    private func replan() {
        let input: (plan: (steps: [KokoroNamePlanner.Step], units: DistanceUnits, preset: KokoroPreset), words: KokoroLexicon, version: Int)? = locked {
            guard let lastPlan, let lexicon else { return nil }
            return (lastPlan, lexicon, planVersion)
        }
        guard let input else { return }
        let requests = KokoroNamePlanner.requests(steps: input.plan.steps, units: input.plan.units, knows: input.words.knows)
            .map { Request(key: Key(preset: input.plan.preset.id, firstKey: $0.firstKey, name: $0.name),
                           text: $0.text, preset: input.plan.preset) }
        prepare(requests, version: input.version)
    }

    func prepare(_ requests: [Request]) {
        prepare(requests, version: nil)
    }

    private func prepare(_ requests: [Request], version: Int?) {
        let applied: Bool = locked {
            if let version, version != planVersion { return false }
            window = Set(requests.map(\.key))
            let busy = inFlight.flatMap { $0.generation == generation ? $0.key : nil }
            var seen = Set<Key>()
            queue = requests.filter {
                seen.insert($0.key).inserted && cache[$0.key] == nil && !attempted.contains($0.key) && $0.key != busy
            }
            cache = cache.filter { window.contains($0.key) }
            attempted = attempted.filter { window.contains($0) }
            return true
        }
        if applied { kick() }
    }

    func setActive(_ isActive: Bool) {
        locked { active = isActive }
        if isActive { kick() }
    }

    func audio(preset: KokoroPreset, firstKey: String, name: String) -> [Float]? {
        locked { cache[Key(preset: preset.id, firstKey: firstKey, name: name)] }
    }

    func memoryWarning() {
        let inTrip = locked { tripActive }
        if inTrip {
            reset(blocking: true)
        } else {
            locked { previewToken += 1 }
            synthesizer.queue.async { [self] in synthesizer.unloadOnQueue() }
        }
        KokoroSynthesizer.log.notice("Kokoro engine unloaded after a memory warning")
    }

    private func reset(blocking: Bool) {
        let rtfs: [Double] = locked {
            let values = tripRTFs
            generation += 1
            window.removeAll()
            queue.removeAll()
            attempted.removeAll()
            tripRTFs.removeAll()
            cache.removeAll()
            engineReady = false
            lexicon = nil
            if blocking {
                tripBlocked = true
            } else {
                tripActive = false
                lastPlan = nil
            }
            return values
        }
        if rtfs.count >= 3, let median = KokoroSupport.median(rtfs) { storeRTF(median) }
        synthesizer.queue.async { [self] in
            // A trip that began since then keeps the engine it is about to use.
            if blocking || !locked({ tripActive }) { synthesizer.unloadOnQueue() }
        }
    }

    // MARK: Worker

    private func kick() {
        let job: (request: Request, generation: Int)? = locked {
            guard inFlight == nil, active, !tripBlocked, engineReady,
                  thermalState().rawValue < ProcessInfo.ThermalState.serious.rawValue else { return nil }
            while !queue.isEmpty {
                let request = queue.removeFirst()
                if cache[request.key] == nil, !attempted.contains(request.key) {
                    inFlight = (generation, request.key)
                    return (request, generation)
                }
            }
            return nil
        }
        guard let job else { return }
        synthesizer.queue.async { [self] in
            let knows = synthesizer.lexicon.map { words in { (word: String) in words.knows(word) } } ?? { _ in false }
            let result = synthesizer.render(job.request.text, preset: job.request.preset, knows: knows)
            let fits = result.map { fitsAllowance($0.samples, job.request) } ?? false
            complete(job.request, generation: job.generation, result: result, fits: fits)
        }
    }

    private func fitsAllowance(_ samples: [Float], _ request: Request) -> Bool {
        guard let nameFree = nameFreeDuration(request.preset, request.key.firstKey) else { return false }
        return Double(samples.count) / KokoroSynthesizer.outputRate <= nameFree + Self.firstClipAllowance
    }

    private func complete(_ request: Request, generation started: Int, result: (samples: [Float], rtf: Double)?, fits: Bool) {
        locked {
            inFlight = nil
            guard started == generation else { return }
            if let result { tripRTFs.append(result.rtf) }
            guard window.contains(request.key) else { return }
            if let result, fits {
                cache[request.key] = result.samples
            } else {
                attempted.insert(request.key)
            }
        }
        kick()
    }

    // MARK: Preview

    /// Renders one sentence for the settings page. Loads the engine if needed.
    func renderPreview(text: String, preset: KokoroPreset) async -> PreviewResult {
        let token: Int = locked {
            previewToken += 1
            return previewToken
        }
        return await withCheckedContinuation { continuation in
            synthesizer.queue.async { [self] in
                continuation.resume(returning: previewJob(text: text, preset: preset, token: token))
            }
        }
    }

    /// On the synthesizer's queue.
    private func previewJob(text: String, preset: KokoroPreset, token: Int) -> PreviewResult {
        func valid() -> Bool { locked { previewToken == token && active && !tripActive } }
        guard valid() else { return .cancelled }
        guard synthesizer.loadOnQueue() else { return .failed }
        // Loading can take seconds: check again before spending the CPU.
        guard valid() else {
            if !locked({ active || tripActive }) { synthesizer.unloadOnQueue() }
            return .cancelled
        }
        let knows = synthesizer.lexicon.map { words in { (word: String) in words.knows(word) } } ?? { _ in false }
        let result = synthesizer.render(text, preset: preset, knows: knows)
        guard locked({ previewToken == token }) else { return .cancelled }
        guard let result else { return .failed }
        return .rendered(samples: result.samples, rtf: result.rtf)
    }

    /// Cancels any queued or running preview and unloads the engine unless a trip uses it.
    func endPreview() {
        locked { previewToken += 1 }
        synthesizer.queue.async { [self] in
            if !locked({ tripActive }) { synthesizer.unloadOnQueue() }
        }
    }
}
