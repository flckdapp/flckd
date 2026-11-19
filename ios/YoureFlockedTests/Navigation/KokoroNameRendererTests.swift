import XCTest
@preconcurrency import FerrostarCoreFFI
@testable import YoureFlocked

/// Lets a test stop the engine inside a load or a render, act, then let it go.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func hold() { lock.lock(); held = true; lock.unlock() }

    func pass() {
        lock.lock(); let wait = held; lock.unlock()
        guard wait else { return }
        entered.signal()
        released.wait()
    }

    func waitUntilEntered(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "engine never reached the gate", file: file, line: line)
    }

    func release() {
        lock.lock(); held = false; lock.unlock()
        released.signal()
    }
}

final class HoldableEngine: KokoroEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var loadCount = 0
    let generateGate = Gate()
    let loadGate = Gate()
    var loadSucceeds = true
    /// Seconds of audio per text; nil means the engine returns nothing.
    var seconds: (String) -> Double? = { _ in 1.0 }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return texts }
    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }

    func load(lexicon: KokoroLexicon) -> (engine: KokoroEngine, lexicon: KokoroLexicon)? {
        loadGate.pass()
        lock.lock(); loadCount += 1; lock.unlock()
        return loadSucceeds ? (self, lexicon) : nil
    }

    func generate(text: String, sid: Int) -> (samples: [Float], sampleRate: Int)? {
        generateGate.pass()
        lock.lock(); texts.append(text); lock.unlock()
        guard let seconds = seconds(text) else { return nil }
        return (Array(repeating: 0.1, count: Int(seconds * 24_000)), 24_000)
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class KokoroNameRendererTests: XCTestCase {
    private let preset = KokoroPreset(id: "heart", name: "Heart", sid: 3, gainDB: 0)
    private let lexicon = KokoroLexicon(words: Set("in five hundred feet a quarter half mile turn right left onto main street oak avenue park road example boulevard elm lane at the roundabout take second exit".split(separator: " ").map(String.init)))

    private var engine: HoldableEngine!
    private var synthesizer: KokoroSynthesizer!
    private var renderer: KokoroNameRenderer!
    private var center: NotificationCenter!
    private var thermal: Box<ProcessInfo.ThermalState>!
    private var stored: Box<[Double]>!

    override func setUp() {
        engine = HoldableEngine()
        let engine = engine!, lexicon = lexicon
        synthesizer = KokoroSynthesizer(factory: { engine.load(lexicon: lexicon) })
        center = NotificationCenter()
        let thermal = Box(ProcessInfo.ThermalState.nominal)
        let stored = Box<[Double]>([])
        self.thermal = thermal
        self.stored = stored
        renderer = KokoroNameRenderer(synthesizer: synthesizer, thermalState: { thermal.value },
                                      nameFreeDuration: { _, _ in 1.0 }, namesEnabled: { true },
                                      storeRTF: { stored.value.append($0) }, notificationCenter: center)
    }

    /// Waits for the synthesizer queue to go idle, including work it queues for itself.
    private func settle() {
        for _ in 0..<8 { synthesizer.queue.sync {} }
    }

    private func request(_ name: String, key: String = "500ft.turn_right") -> KokoroNameRenderer.Request {
        KokoroNameRenderer.Request(key: .init(preset: preset.id, firstKey: key, name: name),
                                   text: "In five hundred feet, turn right onto \(name).", preset: preset)
    }

    private func cached(_ r: KokoroNameRenderer.Request) -> Bool {
        renderer.audio(preset: preset, firstKey: r.key.firstKey, name: r.key.name) != nil
    }

    private func startTrip(active: Bool = true) {
        renderer.setActive(active)
        renderer.beginTrip()
        settle()
    }

    // MARK: Planner and support

    private func content(_ text: String, _ type: FerrostarCoreFFI.ManeuverType = .turn, _ modifier: ManeuverModifier = .right) -> VisualInstructionContent {
        VisualInstructionContent(text: text, maneuverType: type, maneuverModifier: modifier,
                                 roundaboutExitDegrees: nil, laneInfo: nil, exitNumbers: [])
    }

    func testPlannerCoversThreeStepsNearestFirst() {
        let steps = [
            KokoroNamePlanner.Step(banner: content("Main Street"), distance: 1000, roundaboutExitNumber: nil),
            KokoroNamePlanner.Step(banner: content("Example Boulevard", .roundabout, .right), distance: 300, roundaboutExitNumber: nil),
            KokoroNamePlanner.Step(banner: content("Zzyzxq Street"), distance: 5000, roundaboutExitNumber: 2),
            KokoroNamePlanner.Step(banner: content("Oak Avenue"), distance: 1000, roundaboutExitNumber: nil),
        ]
        let requests = KokoroNamePlanner.requests(steps: steps, units: .imperial, knows: lexicon.knows)
        XCTAssertEqual(requests.map(\.firstKey), ["half_mi.turn_right", "quarter_mi.turn_right", "500ft.roundabout_2"])
        XCTAssertEqual(requests.map(\.stepOffset), [0, 0, 1])
        XCTAssertEqual(requests[0].text, "In half a mile, turn right onto Main Street.")
        XCTAssertEqual(requests[2].text, "In five hundred feet, at the roundabout, take the second exit onto Example Boulevard.")
        XCTAssertEqual(requests[2].name, "Example Boulevard")
    }

    func testSupportRule() throws {
        let gb: UInt64 = 1_000_000_000
        XCTAssertFalse(KokoroSupport.namesSupported(physicalMemory: 4 * gb, measuredRTF: nil))
        XCTAssertTrue(KokoroSupport.namesSupported(physicalMemory: 6 * gb, measuredRTF: nil))
        XCTAssertTrue(KokoroSupport.namesSupported(physicalMemory: 6 * gb, measuredRTF: 0.8))
        XCTAssertTrue(KokoroSupport.namesSupported(physicalMemory: 6 * gb, measuredRTF: 1.0))
        XCTAssertFalse(KokoroSupport.namesSupported(physicalMemory: 6 * gb, measuredRTF: 1.2))
        XCTAssertFalse(KokoroSupport.namesSupported(physicalMemory: 4 * gb, measuredRTF: 0.5))

        let suite = "KokoroSupport.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let descriptor = try XCTUnwrap(KokoroPackDescriptor.bundled)
        XCTAssertTrue(KokoroSupport.sayNames(defaults))
        defaults.set(2.0, forKey: KokoroSupport.measuredRTFKey)
        defaults.set("kokoro-some-other-pack", forKey: KokoroSupport.measuredPackKey)
        XCTAssertNil(KokoroSupport.measuredRTF(defaults, descriptor: descriptor))
        KokoroSupport.storeMeasurement(0.7, defaults, descriptor: descriptor)
        XCTAssertEqual(KokoroSupport.measuredRTF(defaults, descriptor: descriptor), 0.7)
        KokoroSupport.clearMeasurement(defaults)
        XCTAssertNil(KokoroSupport.measuredRTF(defaults, descriptor: descriptor))
        XCTAssertFalse(KokoroSupport.namesEnabled(defaults, store: nil))
        XCTAssertEqual(KokoroSupport.median([3, 1, 2]), 2)
        XCTAssertEqual(KokoroSupport.median([1, 2, 3, 4]), 2.5)
    }

    // MARK: Renderer

    func testResultAfterTripEndIsDiscarded() {
        startTrip()
        let a = request("Main Street")
        engine.generateGate.hold()
        renderer.prepare([a])
        engine.generateGate.waitUntilEntered()
        renderer.endTrip()
        engine.generateGate.release()
        settle()
        XCTAssertFalse(cached(a))
        XCTAssertEqual(stored.value, [])
    }

    func testResultWhoseKeyLeftTheWindowIsDiscarded() {
        startTrip()
        let a = request("Main Street"), b = request("Oak Avenue")
        engine.generateGate.hold()
        renderer.prepare([a])
        engine.generateGate.waitUntilEntered()
        renderer.prepare([b])
        engine.generateGate.release()
        settle()
        XCTAssertFalse(cached(a))
        XCTAssertTrue(cached(b))
    }

    func testFailedAndOverlongRendersAreTriedOnceAndDoNotBlock() {
        startTrip()
        let a = request("Main Street"), b = request("Oak Avenue"), c = request("Park Road")
        engine.seconds = { text in text.contains("Main") ? nil : text.contains("Oak") ? 4.0 : 1.0 }
        renderer.prepare([a, b, c])
        settle()
        XCTAssertEqual(engine.calls, [a.text, b.text, c.text])
        XCTAssertFalse(cached(a))
        XCTAssertFalse(cached(b), "a first clip 3 s longer than the name-free one must be rejected")
        XCTAssertTrue(cached(c))
        renderer.prepare([a, b, c])
        settle()
        XCTAssertEqual(engine.calls.count, 3, "a rejected request is not retried in the same window")
    }

    func testNothingRendersWhileInactiveAndForegroundResumes() {
        startTrip(active: false)
        let a = request("Main Street")
        renderer.prepare([a])
        settle()
        XCTAssertEqual(engine.calls, [])
        renderer.setActive(true)
        settle()
        XCTAssertEqual(engine.calls, [a.text])
        XCTAssertTrue(cached(a))
    }

    func testHeatPausesAndTheThermalNotificationResumes() {
        startTrip()
        thermal.value = .serious
        let a = request("Main Street")
        renderer.prepare([a])
        settle()
        XCTAssertEqual(engine.calls, [])
        thermal.value = .fair
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        settle()
        XCTAssertEqual(engine.calls, [a.text])
    }

    func testRenderInFlightWhenBackgroundedStillCountsButNoMoreStart() {
        startTrip()
        let a = request("Main Street"), b = request("Oak Avenue")
        engine.generateGate.hold()
        renderer.prepare([a, b])
        engine.generateGate.waitUntilEntered()
        renderer.setActive(false)
        engine.generateGate.release()
        settle()
        XCTAssertTrue(cached(a))
        XCTAssertEqual(engine.calls, [a.text])
    }

    func testMemoryWarningStopsRenderingUntilTheNextTrip() {
        startTrip()
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let a = request("Main Street")
        renderer.prepare([a])
        settle()
        XCTAssertEqual(engine.calls, [])
        renderer.beginTrip()
        settle()
        renderer.prepare([a])
        settle()
        XCTAssertEqual(engine.calls, [a.text])
    }

    func testRepeatedPrepareDuringARenderDoesNotRenderTwice() {
        startTrip()
        let a = request("Main Street"), b = request("Oak Avenue")
        engine.generateGate.hold()
        renderer.prepare([a])
        engine.generateGate.waitUntilEntered()
        renderer.prepare([a, b, a])
        engine.generateGate.release()
        settle()
        XCTAssertEqual(engine.calls.filter { $0 == a.text }.count, 1)
        XCTAssertTrue(cached(a))
        XCTAssertTrue(cached(b))
    }

    func testTripMedianCountsRejectedRendersButNotFailuresOrStaleResults() {
        startTrip()
        engine.seconds = { $0.contains("Elm") ? nil : 4.0 }
        let rejected = [request("Main Street"), request("Oak Avenue"), request("Park Road")]
        renderer.prepare(rejected + [request("Elm Lane")])
        settle()
        XCTAssertEqual(engine.calls.count, 4)
        let late = request("Example Boulevard")
        engine.generateGate.hold()
        renderer.prepare([late])
        engine.generateGate.waitUntilEntered()
        renderer.endTrip()
        engine.generateGate.release()
        settle()
        XCTAssertEqual(stored.value.count, 1, "one median for three audio-producing renders")
        XCTAssertGreaterThan(stored.value.first ?? 0, 0)
        renderer.beginTrip()
        settle()
        renderer.endTrip()
        settle()
        XCTAssertEqual(stored.value.count, 1, "the stale render added nothing")
    }

    func testRestartedTripRendersTheSameKeyAgain() {
        startTrip()
        let k = request("Main Street")
        engine.generateGate.hold()
        renderer.prepare([k])
        engine.generateGate.waitUntilEntered()
        renderer.endTrip()
        renderer.beginTrip()
        renderer.prepare([k])
        engine.generateGate.release()
        settle()
        XCTAssertEqual(engine.calls, [k.text, k.text])
        XCTAssertTrue(cached(k))
        XCTAssertEqual(stored.value, [])
    }

    // MARK: Previews

    private func preview() -> Task<KokoroNameRenderer.PreviewResult, Never> {
        let renderer = renderer!, preset = preset
        return Task { await renderer.renderPreview(text: "In five hundred feet, turn right onto Main Street.", preset: preset) }
    }

    private func assertCancelledDuringLoad(_ action: () -> Void) async {
        renderer.setActive(true)
        engine.loadGate.hold()
        let task = preview()
        engine.loadGate.waitUntilEntered()
        action()
        engine.loadGate.release()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(engine.calls, [])
    }

    func testBackgroundingDuringALoadCancelsThePreview() async {
        await assertCancelledDuringLoad { renderer.setActive(false) }
    }

    func testLeavingThePageDuringALoadCancelsThePreview() async {
        await assertCancelledDuringLoad { renderer.endPreview() }
    }

    func testATripStartingDuringALoadCancelsThePreview() async {
        await assertCancelledDuringLoad { renderer.beginTrip() }
    }

    func testPreviewsLoadColdAndAgainAfterEndPreview() async {
        renderer.setActive(true)
        var result = await preview().value
        guard case .rendered = result else { return XCTFail("\(result)") }
        renderer.endPreview()
        settle()
        result = await preview().value
        guard case .rendered = result else { return XCTFail("\(result)") }
        XCTAssertEqual(engine.loads, 2)
    }

    func testPreviewFailures() async {
        renderer.setActive(true)
        engine.seconds = { _ in nil }
        var result = await preview().value
        XCTAssertEqual(result, .failed)
        renderer.endPreview()
        settle()
        engine.loadSucceeds = false
        result = await preview().value
        XCTAssertEqual(result, .failed)
    }

    func testSupersededPreviewIsCancelled() async {
        renderer.setActive(true)
        engine.generateGate.hold()
        let first = preview()
        engine.generateGate.waitUntilEntered()
        let second = preview()
        engine.generateGate.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .cancelled)
        guard case .rendered = secondResult else { return XCTFail("\(secondResult)") }
    }

    func testEndPreviewOrTripDuringARenderCancelsIt() async {
        renderer.setActive(true)
        for action in [{ self.renderer.endPreview() }, { self.renderer.beginTrip() }] {
            engine.generateGate.hold()
            let task = preview()
            engine.generateGate.waitUntilEntered()
            action()
            engine.generateGate.release()
            let result = await task.value
            XCTAssertEqual(result, .cancelled)
            renderer.endTrip()
            settle()
        }
    }

    func testPreviewQueuedWhileInactiveNeverTouchesTheEngine() async {
        renderer.setActive(false)
        let result = await preview().value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(engine.loads, 0)
        XCTAssertEqual(engine.calls, [])
    }

    // MARK: Player and queue

    func testNamedAudioIsUsedOnlyWhenCachedAndShortEnough() throws {
        let root = TestDirectories.fresh()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KokoroVoiceStore(root: root, descriptor: try XCTUnwrap(KokoroPackDescriptor.bundled))
        let heart = try XCTUnwrap(KokoroPreset.named("heart"))
        let dir = store.clipsDirectory(preset: "heart")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for key in ["500ft.turn_right", "lane_right"] { try Data([1]).write(to: dir.appendingPathComponent("\(key).m4a")) }

        var utterance = VoiceUtterance(clips: ["500ft.turn_right", "lane_right"], createdAt: 0)
        utterance.kokoro = heart
        utterance.roadName = "Main Street"
        let rate = 44_100.0
        func loader(_ named: [Float]?) -> VoiceClipLoader {
            VoiceClipLoader(store: store, decode: { _, _ in Array(repeating: 0.1, count: Int(rate)) },
                            namedAudio: { preset, firstKey, name in
                                XCTAssertEqual(preset, heart); XCTAssertEqual(firstKey, "500ft.turn_right"); XCTAssertEqual(name, "Main Street")
                                return named
                            }, sampleRate: rate)
        }
        var stats = KokoroStats()
        let short = try loader(Array(repeating: 0.2, count: Int(rate * 2))).samples(for: utterance)
        XCTAssertTrue(short.named)
        XCTAssertEqual(short.clips[0].count, Int(rate * 2))
        stats.record(utterance, playedKokoro: short.kokoro, named: short.named)

        let missing = try loader(nil).samples(for: utterance)
        XCTAssertTrue(missing.kokoro)
        XCTAssertFalse(missing.named)
        stats.record(utterance, playedKokoro: missing.kokoro, named: missing.named)

        // 4.5 s + 1 s + 0.35 s join is over 5 s.
        let long = try loader(Array(repeating: 0.2, count: Int(rate * 4.5))).samples(for: utterance)
        XCTAssertFalse(long.named)
        XCTAssertEqual(long.clips[0].count, Int(rate))
        stats.record(utterance, playedKokoro: long.kokoro, named: long.named)
        XCTAssertEqual(stats, KokoroStats(requested: 3, spoken: 3, named: 1))
    }

    func testCameraAlertSurvivesTheLongestNamedUtterance() {
        var queue = VoicePromptQueue()
        let start: TimeInterval = 100
        queue.enqueue(VoiceUtterance(clips: ["cam.flock.ahead"], priority: .camera, kind: .camera(.flock),
                                     createdAt: start + 0.3))
        let next = queue.next(now: start + VoiceClipLoader.namedUtteranceLimit)
        XCTAssertEqual(next?.clips, ["cam.flock.ahead"])
    }
}

final class KokoroNameRendererReviewTests: XCTestCase {
    private let preset = KokoroPreset(id: "heart", name: "Heart", sid: 3, gainDB: 0)
    private let lexicon = KokoroLexicon(words: ["in", "five", "hundred", "feet", "turn", "right", "onto", "main", "street", "oak", "avenue"])

    private func make(namesEnabled: Bool = true) -> (KokoroNameRenderer, KokoroSynthesizer, HoldableEngine) {
        let engine = HoldableEngine()
        let lexicon = lexicon
        let synthesizer = KokoroSynthesizer(factory: { engine.load(lexicon: lexicon) })
        let renderer = KokoroNameRenderer(synthesizer: synthesizer, thermalState: { .nominal },
                                          nameFreeDuration: { _, _ in 1.0 }, namesEnabled: { namesEnabled },
                                          storeRTF: { _ in }, notificationCenter: NotificationCenter())
        return (renderer, synthesizer, engine)
    }

    private func settle(_ synthesizer: KokoroSynthesizer) { for _ in 0..<8 { synthesizer.queue.sync {} } }

    private func request(_ name: String) -> KokoroNameRenderer.Request {
        .init(key: .init(preset: preset.id, firstKey: "500ft.turn_right", name: name),
              text: "In five hundred feet, turn right onto \(name).", preset: preset)
    }

    func testAReplanFromAnEndedTripPublishesNothing() {
        let (renderer, synthesizer, engine) = make()
        renderer.setActive(true)
        renderer.beginTrip()
        settle(synthesizer)
        let stale = renderer.currentPlanVersion
        renderer.endTrip()
        renderer.beginTrip()
        settle(synthesizer)
        renderer.prepare([request("Main Street")], version: stale)
        settle(synthesizer)
        XCTAssertEqual(engine.calls, [])
        XCTAssertNil(renderer.audio(preset: preset, firstKey: "500ft.turn_right", name: "Main Street"))
    }

    func testATripWithoutNamesUnloadsAPreviewsEngine() async {
        let (renderer, synthesizer, engine) = make(namesEnabled: false)
        renderer.setActive(true)
        engine.loadGate.hold()
        let preset = preset
        let task = Task { await renderer.renderPreview(text: "Turn right onto Main Street.", preset: preset) }
        engine.loadGate.waitUntilEntered()
        renderer.beginTrip()
        engine.loadGate.release()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        settle(synthesizer)
        XCTAssertFalse(synthesizer.queue.sync { synthesizer.isLoaded })
    }

    func testAJobQueuedBeforeBackgroundingDoesNotStartUntilForeground() {
        let (renderer, synthesizer, engine) = make()
        renderer.setActive(true)
        renderer.beginTrip()
        settle(synthesizer)
        let blocker = DispatchSemaphore(value: 0)
        synthesizer.queue.async { blocker.wait() }
        let a = request("Main Street")
        renderer.prepare([a])
        renderer.setActive(false)
        blocker.signal()
        settle(synthesizer)
        XCTAssertEqual(engine.calls, [])
        renderer.setActive(true)
        settle(synthesizer)
        XCTAssertEqual(engine.calls, [a.text])
        XCTAssertNotNil(renderer.audio(preset: preset, firstKey: a.key.firstKey, name: a.key.name))
    }
}
