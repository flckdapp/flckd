#if DEBUG
import SwiftUI

/// Native settings form for on-device speech measurements. No choice here changes
/// the navigation voice. Results and free text live only for this page.
struct PhononEvaluationView: View {
    @Environment(NavigationSessionController.self) private var navigation
    @Environment(ProximityAlertEngine.self) private var proximity
    @Environment(LocationManager.self) private var locationManager
    @Environment(CameraStore.self) private var cameraStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var evaluation = PhononEvaluation()
    @State private var items: [PhononSentences.Item] = []
    @State private var selection = "turn_left"
    @State private var freeText = "Hello. This is a voice comparison."
    @State private var voice = ""
    private var tripRunning: Bool { navigation.isActive || navigation.isStarting }
    private var selected: PhononSentences.Item? { items.first { $0.id == selection } }
    private var text: String? { selection == "free" ? freeText : selected?.text }

    var body: some View {
        Form {
            if ProcessInfo.processInfo.arguments.contains("-speechSyntheticDrive") {
                Section("Synthetic drive") {
                    Text(evaluation.status).accessibilityIdentifier("synthetic-drive-status")
                }
            }
            Section {
                Picker("Phonon voice", selection: $voice) {
                    if evaluation.voices.isEmpty { Text("Load voices first").tag("") }
                    ForEach(PhononSentences.voices.filter(evaluation.voices.contains), id: \.self) {
                        Text($0 == "Easton" ? "Easton - Male" : "Harper - Female").tag($0)
                    }
                }
                Button("Load Phonon Voices") { evaluation.load() }.disabled(evaluation.running)
            } footer: {
                Text("Bench only. Bundled models; no downloads. The first load compiles on this device.")
            }
            Section("Sentence") {
                Picker("Example", selection: $selection) {
                    ForEach(items) { item in
                        Text(item.title + (item.text == nil ? " (rejected)" : "")).tag(item.id)
                    }
                    Text("Free text").tag("free")
                }
                if selection == "free" {
                    TextField("Text to speak", text: $freeText, axis: .vertical)
                        .autocorrectionDisabled().textInputAutocapitalization(.sentences)
                        .privacySensitive()
                } else {
                    Text(text ?? "This fixture is rejected by SpokenRoadName. Nothing is rendered.")
                        .foregroundStyle(text == nil ? .secondary : .primary)
                }
                if let text, !PhononSentences.accepts(text) {
                    Text("Use letters and punctuation, no digits or symbols. Limit: six hundred characters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Play Phonon") {
                    if let text { evaluation.playPhonon(text, voice: voice) }
                }.disabled(evaluation.running || voice.isEmpty || !canRender)
                Button("Play \(PromptVoice.selected.name) Recording") {
                    if let key = selected?.recordedKey { evaluation.playRecorded(key) }
                }.disabled(evaluation.running || selection == "free" || selected?.recordedKey == nil)
                Button("Stop", role: .cancel) { evaluation.stop() }
            } header: {
                Text("Listen")
            } footer: {
                Text("Recordings cover fixed prompts only, not names or free text. All playback uses the normal prompt player.")
            }
            Section("Measure") {
                Button("Run Short + Long Bench") { evaluation.bench(voice: voice) }
                    .disabled(evaluation.running || voice.isEmpty)
                Button("Unload Phonon") { evaluation.unload() }.disabled(evaluation.running)
            }
            Section("Status") {
                Text(evaluation.status).font(.caption).accessibilityIdentifier("phonon-status")
                if evaluation.running { ProgressView() }
                ForEach(Array(evaluation.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section("Licences") {
                NavigationLink("Phonon 31m - Apache 2.0") { LicenceTextView(title: "Phonon 31m", resource: "phonon-31m") }
                NavigationLink("xn-ptts - MIT OR Apache 2.0") { LicenceTextView(title: "xn-ptts", resource: "xn-ptts") }
            }
        }
        .navigationTitle("Phonon A/B")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(tripRunning)
        .task {
            do { items = try PhononSentences.load() }
            catch { evaluation.status = "Sentence fixtures are missing. Rebuild Debug." }
            if ProcessInfo.processInfo.arguments.contains("-phononSmoke") { evaluation.smoke() }
            if ProcessInfo.processInfo.arguments.contains("-speechSyntheticDrive") { await syntheticDrive() }
        }
        .onChange(of: evaluation.voices) { _, voices in
            if !voices.contains(voice) { voice = voices.contains("Easton") ? "Easton" : voices.first ?? "" }
        }
        .onChange(of: tripRunning) { _, running in if running { evaluation.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { evaluation.stop() } }
        .onDisappear { evaluation.stop() }
    }

    private var canRender: Bool { text.map(PhononSentences.accepts) ?? false }

    @MainActor
    private func syntheticDrive() async {
        evaluation.status = "Synthetic drive warming up."
        let defaults = UserDefaults.standard
        let keys = [NavigationVoice.storageKey, VoiceSettings.masterKey, VoiceSettings.directionsKey,
                    DebugDriveSimulationSettings.speedKey, DebugDriveSimulationSettings.timeKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            navigation.stop()
            PhononSpeechService.shared.forceFailure = false
            VoicePromptPlayer.shared.stopAll()
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        do {
            guard ProcessInfo.processInfo.environment["FLCKD_TEST_DISABLE_ACTIVITY_REQUESTS"] == "1",
                  let encoded = ProcessInfo.processInfo.environment["FLCKD_SYNTHETIC_ROUTE"],
                  let response = Data(base64Encoded: encoded),
                  let route = try FlckdRouteProvider.routes(fromOSRM: response).first,
                  let destination = route.geometry.last else { throw PhononSynthesizer.Failure.invalidText }
            defaults.set("easton", forKey: NavigationVoice.storageKey)
            defaults.set(true, forKey: VoiceSettings.masterKey)
            defaults.set(true, forKey: VoiceSettings.directionsKey)
            let multi = ProcessInfo.processInfo.arguments.contains("-speechMultiPromptDrive")
            defaults.set(multi ? 70 : 35, forKey: DebugDriveSimulationSettings.speedKey)
            defaults.set(multi ? 1 : 2, forKey: DebugDriveSimulationSettings.timeKey)
            PhononSpeechService.shared.setForeground(true)
            try await PhononSpeechService.shared.unloadForTesting()
            if multi {
                PhononSpeechService.shared.warmUp()
                let end = ProcessInfo.processInfo.systemUptime + 20
                while !PhononSpeechService.shared.loaded, ProcessInfo.processInfo.systemUptime < end {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard PhononSpeechService.shared.loaded else { throw PhononSynthesizer.Failure.missingModels }
            }
            evaluation.status = "Synthetic drive starting."
            let plan = RoutePlan(route: ValhallaRoute(coordinates: route.geometry.map(\.clLocationCoordinate2D),
                distanceKm: route.distance / 1000, timeSeconds: 42, maneuvers: []),
                avoidedCount: 0, totalCount: 0, requestJSON: Data("{}".utf8), candidateIndex: 0)
            let recorded = VoicePlaybackDiagnostics.recordedCount, opening = VoicePlaybackDiagnostics.openingCount
            let checkCameras = ProcessInfo.processInfo.arguments.contains("-cameraExposureDrive")
            var routeCameras: [SurveillanceCamera] = []
            if checkCameras, let encodedCameras = ProcessInfo.processInfo.environment["FLCKD_SYNTHETIC_CAMERAS"],
               let data = Data(base64Encoded: encodedCameras),
               let values = try JSONSerialization.jsonObject(with: data) as? [[String: Double]] {
                routeCameras = values.enumerated().map { index, value in
                    SurveillanceCamera(osmID: Int64(index + 1), latitude: value["latitude"] ?? 0,
                        longitude: value["longitude"] ?? 0, tags: ["surveillance:type": "ALPR", "brand": "Flock", "direction": "270"])
                }
            }
            let expectedExposed = CameraObservability.RouteExposure.build(path: route.geometry.map(\.clLocationCoordinate2D), cameras: routeCameras).exposedIDs.count
            navigation.simulateDrive = true
            navigation.debugNavigationResponse = response
            await navigation.start(plan: plan, destination: .init(name: "Example destination", coordinate: destination.clLocationCoordinate2D), routeCameras: routeCameras)
            let liveEnd = ProcessInfo.processInfo.systemUptime + VoiceRenderPolicy.openingDeadline + 0.5
            while VoicePlaybackDiagnostics.openingCount == opening, ProcessInfo.processInfo.systemUptime < liveEnd {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard VoicePlaybackDiagnostics.openingCount > opening, VoicePlaybackDiagnostics.recordedCount == recorded else {
                navigation.stop()
                await LiveActivityManager.endAllActivities()
                evaluation.status = "Cold drive missing opening: \(VoicePromptPlayer.shared.speechStats().skipped); recordings \(VoicePlaybackDiagnostics.recordedCount - recorded)."
                return
            }
            if multi {
                let before = ProcessInfo.processInfo.systemUptime
                let end = ProcessInfo.processInfo.systemUptime + 48
                var cameraSent = false
                while navigation.isActive, ProcessInfo.processInfo.systemUptime < end {
                    if checkCameras, let fix = locationManager.currentLocation {
                        proximity.updateCameraSpeech(location: fix, cameraStore: cameraStore, alertRadius: 100,
                            inFieldOfView: false, alertsEnabled: true)
                    }
                    let events = RoutingMetricsStore.shared.speechEvents.filter { $0.uptime >= before }
                    if !cameraSent, events.contains(where: { $0.kind == .guidance && $0.stage == .completed }) {
                        // Exercise the normal camera queue between route directions.
                        VoicePromptPlayer.shared.enqueue(.init(clips: ["cam.flock.ahead"], priority: .camera,
                            kind: .camera(.flock), createdAt: ProcessInfo.processInfo.systemUptime, liveVoice: .easton))
                        cameraSent = true
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await Task.sleep(for: .seconds(2))
                let events = RoutingMetricsStore.shared.speechEvents.filter { $0.uptime >= before }
                let guidance = events.filter { $0.kind == .guidance && $0.stage == .played }.count
                let cameras = events.filter { $0.kind == .camera && $0.stage == .played }.count
                let skipped = events.filter { $0.stage == .skipped }.count
                let finished = !navigation.isActive
                if checkCameras {
                    let count = navigation.tripSummary?.camerasEncountered ?? -1
                    evaluation.status = finished && expectedExposed == 2 && count == expectedExposed
                        ? "Camera drive: preview 2, summary 2."
                        : "Camera drive failed: preview \(expectedExposed), summary \(count)."
                    await LiveActivityManager.endAllActivities()
                    return
                }
                navigation.stop()
                await LiveActivityManager.endAllActivities()
                evaluation.status = finished && guidance >= 4 && cameras >= 1 && skipped == 0
                    && VoicePlaybackDiagnostics.recordedCount == recorded
                    ? "Multi-step drive: four directions and camera played; no skips or recordings."
                    : "Multi-step drive failed: guidance \(guidance), cameras \(cameras), skips \(skipped), finished \(finished)."
                return
            }
            navigation.stop()
            await LiveActivityManager.endAllActivities()
            evaluation.status = "Cold opening played in Phonon; no recordings; stopped and cleaned up."
        } catch {
            navigation.stop()
            await LiveActivityManager.endAllActivities()
            evaluation.status = "Synthetic drive failed (\(String(describing: type(of: error))))."
        }
    }
}

@MainActor
@Observable
final class PhononEvaluation {
    private let engine = PhononSynthesizer()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var firstLoad: PhononSynthesizer.Load?
    var voices: [String] = []
    var lines: [String] = []
    var running = false
    var status = "Load voices, then choose a sentence. Nothing here changes navigation."

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !running else { return }
        running = true
        status = "Working"
        let generation = generation
        task = Task {
            do {
                try await work()
                try Task.checkCancellation()
                if generation == self.generation { status = "Done" }
            } catch {
                // Do not surface upstream error descriptions: they may hold input.
                if generation == self.generation { status = "Could not render. Check the model, voice and text rules." }
            }
            if generation == self.generation { running = false }
        }
    }

    func load() {
        run {
            let load = try await self.engine.load()
            try Task.checkCancellation()
            self.voices = load.voices
            if self.firstLoad == nil { self.firstLoad = load }
            self.lines.append(String(format: "Phonon %@ load %.2f s", load.compiled ? "compile +" : "cached", load.seconds))
        }
    }

    /// Fixed generic input only. Lets simulator validation bypass XCTest's
    /// host handshake while still exercising the real player and session.
    func smoke() {
        run {
            let load = try await self.engine.load()
            try Task.checkCancellation()
            self.voices = load.voices
            self.firstLoad = load
            guard let voice = load.voices.first(where: { $0 == "Easton" }) ?? load.voices.first else {
                throw PhononSynthesizer.Failure.unknownVoice
            }
            let result = try await self.engine.render("Turn left.", voice: voice)
            try Task.checkCancellation()
            self.record(result, label: "Phonon smoke")
            self.play(result.samples)
            print(String(format: "PHONON_SMOKE load=%.3f compile=%@ render=%.3f first=%.3f rtf=%.3f peak=%llu gain=%.2f lufs=%.2f frames=%d",
                         load.seconds, load.compiled.description, result.seconds, result.firstAudio, result.rtf,
                         result.peakBytes, result.gainDB, result.lufs, result.samples.count))
        }
    }

    func playPhonon(_ text: String, voice: String) {
        run {
            let result = try await self.engine.render(text, voice: voice)
            try Task.checkCancellation()
            self.record(result, label: "Phonon")
            self.play(result.samples)
        }
    }

    func playRecorded(_ key: String) {
        VoicePromptPlayer.shared.enqueue(VoiceUtterance(clips: [key], voice: .selected, priority: .sample,
                                                        kind: .preview, createdAt: ProcessInfo.processInfo.systemUptime))
    }

    private func play(_ samples: [Float]) {
        var utterance = VoiceUtterance(clips: [], priority: .sample, kind: .preview,
                                       createdAt: ProcessInfo.processInfo.systemUptime)
        utterance.renderedPCM = samples
        VoicePromptPlayer.shared.enqueue(utterance)
    }

    private func record(_ result: PhononSynthesizer.Render, label: String) {
        lines.append(String(format: "%@ render %.2f s, first chunk %.2f s, RTF %.2f, gain %.1f dB, output %.1f LUFS, peak %@",
                            label, result.seconds, result.firstAudio, result.rtf, result.gainDB, result.lufs,
                            VoiceDiagnostics.megabytes(result.peakBytes)))
    }

    func bench(voice: String) {
        run {
            self.lines = ["RTF = render seconds / audio seconds; lower is faster. First chunk is engine latency, not playback onset.",
                          "Memory sampled every ten milliseconds; process footprint, not model-only allocation."]
            if let first = self.firstLoad {
                self.lines.append(String(format: "First page load (%@): %.2f s", first.compiled ? "compile + load" : "already compiled", first.seconds))
            }
            try await self.engine.unload()
            try await Task.sleep(for: .milliseconds(500))
            self.lines.append("Before load: \(VoiceDiagnostics.megabytes(VoiceDiagnostics.footprint() ?? 0))")
            let load = try await self.engine.load()
            self.lines.append(String(format: "Phonon %@ load %.2f s", load.compiled ? "compile +" : "cached", load.seconds))
            self.lines.append("After load: \(VoiceDiagnostics.megabytes(VoiceDiagnostics.footprint() ?? 0))")
            try await self.engine.unload()
            try await Task.sleep(for: .milliseconds(500))
            let warm = try await self.engine.load()
            self.lines.append(String(format: "Phonon warm reload %.2f s", warm.seconds))
            for (index, sentence) in ["Turn left.", "In a quarter mile, at the roundabout, take the second exit onto Example Boulevard."].enumerated() {
                try Task.checkCancellation()
                let result = try await self.engine.render(sentence, voice: voice)
                self.record(result, label: "Phonon \(index == 0 ? "short" : "long")")
            }
            try await self.engine.unload()
            // The upstream destructor enqueues C destruction asynchronously.
            try await Task.sleep(for: .milliseconds(500))
            self.lines.append("Phonon after unload (500 ms): \(VoiceDiagnostics.megabytes(VoiceDiagnostics.footprint() ?? 0))")
            self.lines.append("Thermal: \(VoiceDiagnostics.name(ProcessInfo.processInfo.thermalState))")
        }
    }

    func unload() {
        run {
            try await self.engine.unload()
            try await Task.sleep(for: .milliseconds(500))
            self.lines.append("After unload (500 ms): \(VoiceDiagnostics.megabytes(VoiceDiagnostics.footprint() ?? 0))")
        }
    }

    func stop() {
        generation += 1
        let stoppingGeneration = generation
        let oldTask = task
        oldTask?.cancel()
        VoicePromptPlayer.shared.cancel(.sample)
        running = true
        status = "Stopped"
        task = Task {
            await oldTask?.value
            do { try await engine.unload() } catch { status = "Engine is still finishing." }
            if generation == stoppingGeneration { running = false }
        }
    }
}
#endif
