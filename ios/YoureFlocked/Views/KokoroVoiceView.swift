import SwiftUI

// MARK: - Kokoro Voice

/// The optional Kokoro voice: download, presets and previews. Reached from the
/// Voice & Spoken Prompts page. Every control is disabled during a trip, so the
/// voice cannot change while guidance is speaking.
struct KokoroVoiceView: View {
    @Environment(NavigationSessionController.self) private var navigationController
    @AppStorage(VoiceEngine.storageKey) private var engineRaw: String = VoiceEngine.recorded.rawValue
    @AppStorage(KokoroPreset.storageKey) private var presetID: String = KokoroPreset.defaultID
    @AppStorage(PromptVoice.storageKey) private var promptVoice: String = PromptVoice.male.rawValue
    @AppStorage(KokoroSupport.sayNamesKey) private var sayNames = true

    private let store = KokoroVoiceStore.standard

    @State private var installedPresets: Set<String> = []
    @State private var isDownloading = false
    @State private var progress: Double = 0
    @State private var downloadError: String?
    @State private var previewError: String?
    @State private var confirmDelete = false
    @State private var modelInstalled = false
    @State private var namesStatus = KokoroSupport.NamesStatus.notInstalled
    @State private var isDownloadingModel = false
    @State private var modelProgress: Double = 0
    @State private var modelError: String?
    @State private var previewing: String?
    /// Bumped when the page goes away or the engine is deleted, so a preview
    /// that finishes afterwards neither plays nor counts as a measurement.
    @State private var previewGeneration = 0

    private var tripRunning: Bool { navigationController.isActive || navigationController.isStarting }
    private var presets: [KokoroPreset] { KokoroPreset.all(store?.descriptor) }
    private var clipsInstalled: Bool { !installedPresets.isEmpty }
    private var fallbackName: String { (PromptVoice(rawValue: promptVoice) ?? .male).name }

    var body: some View {
        Form {
            aboutSection
            if store == nil {
                Section { Text("This build has no Kokoro voice.").foregroundStyle(.secondary) }
            } else {
                downloadSection
                if clipsInstalled {
                    presetSection
                    namesSection
                }
            }
        }
        .navigationTitle("Kokoro")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(tripRunning)
        .onAppear(perform: refresh)
        .onDisappear {
            previewGeneration += 1
            previewing = nil
            KokoroNameRenderer.shared.endPreview()
            VoicePromptPlayer.shared.cancel(.sample)
        }
        .confirmationDialog("Delete the Kokoro voice?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Kokoro", role: .destructive, action: deleteAll)
        } message: {
            Text("\(fallbackName) will speak instead. You can download Kokoro again later.")
        }
    }

    // MARK: Sections

    private var aboutSection: some View {
        Section {
            Text("A different voice, made by a speech model rather than recorded. It can say street names, which the recorded voices can't. It won't sound like Eric or Jessica.")
                .font(.subheadline)
        } footer: {
            Text("Experimental. Try it on a few drives and say which voice you prefer.")
        }
    }

    @ViewBuilder
    private var downloadSection: some View {
        Section {
            if clipsInstalled {
                HStack {
                    Text("Voices")
                    Spacer()
                    Text("Downloaded").foregroundStyle(.secondary)
                }
                Button("Delete Kokoro", role: .destructive) { confirmDelete = true }
                    .disabled(isDownloading)
            } else {
                HStack {
                    Button("Download Voices", action: downloadClips)
                        .disabled(isDownloading)
                    Spacer()
                    if isDownloading {
                        ProgressView(value: progress).frame(width: 80)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    } else if let store {
                        Text(ByteCountFormatter.string(fromByteCount: store.descriptor.clipBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let downloadError {
                Text(downloadError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Download")
        } footer: {
            Text("A one-time download from your tile server, the same files for everyone. Prompts then play from this phone.")
        }
    }

    private var presetSection: some View {
        Section {
            ForEach(presets, id: \.id) { preset in
                HStack {
                    Button {
                        presetID = preset.id
                        engineRaw = VoiceEngine.kokoro.rawValue
                    } label: {
                        HStack {
                            Text(preset.name).foregroundStyle(.primary)
                            Spacer()
                            if isSelected(preset) { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(isSelected(preset) ? .isSelected : [])
                    Button { preview(preset) } label: {
                        Group {
                            if previewing == preset.id {
                                ProgressView()
                            } else {
                                Image(systemName: "play.circle").font(.title2)
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(previewing != nil)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Preview \(preset.name)")
                }
                .disabled(!installedPresets.contains(preset.id))
            }
            if let previewError {
                Text(previewError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("If a Kokoro file is missing, \(fallbackName) says that prompt instead. Previews are unavailable during navigation.")
        }
    }

    @ViewBuilder
    private var namesSection: some View {
        Section {
            Toggle("Say Street Names", isOn: $sayNames)
            switch namesStatus {
            case .needsMoreMemory:
                Text("Street names need a phone with more memory.")
                    .foregroundStyle(.secondary)
            case .notInstalled:
                HStack {
                    Button("Download Street-Name Engine", action: downloadModel)
                        .disabled(isDownloadingModel)
                    Spacer()
                    if isDownloadingModel {
                        ProgressView(value: modelProgress).frame(width: 80)
                        Text("\(Int(modelProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    } else if let store {
                        Text(ByteCountFormatter.string(fromByteCount: store.descriptor.modelBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            case .tooSlow:
                Text("Street names were too slow on this phone.")
                    .foregroundStyle(.secondary)
                Button("Test Again") { preview(selectedPreset) }
                    .disabled(previewing != nil)
                deleteModelButton
            case .ready:
                HStack {
                    Text("Street-Name Engine")
                    Spacer()
                    Text("Downloaded").foregroundStyle(.secondary)
                }
                deleteModelButton
            }
            if let modelError {
                Text(modelError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Street Names")
        } footer: {
            Text("Kokoro can add the street name to turn prompts, rendered on this phone a few seconds ahead while the app is on screen. If a name isn't ready, or has a word Kokoro doesn't know, the prompt plays without it.")
        }
    }

    private var deleteModelButton: some View {
        Button("Delete Engine", role: .destructive, action: deleteModel)
            .disabled(isDownloadingModel || previewing != nil)
    }

    private var selectedPreset: KokoroPreset {
        KokoroPreset.named(presetID, in: store?.descriptor) ?? presets.first
            ?? KokoroPreset(id: KokoroPreset.defaultID, name: "", sid: 0, gainDB: 0)
    }

    // MARK: Actions

    private func isSelected(_ preset: KokoroPreset) -> Bool {
        engineRaw == VoiceEngine.kokoro.rawValue && presetID == preset.id
    }

    private func refresh() {
        guard let store else { return }
        installedPresets = Set(presets.filter { store.clipsInstalled(preset: $0) }.map(\.id))
        modelInstalled = store.modelInstalled()
        namesStatus = KokoroSupport.namesStatus(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                                modelInstalled: modelInstalled,
                                                measuredRTF: KokoroSupport.measuredRTF(descriptor: store.descriptor))
    }

    private func preview(_ preset: KokoroPreset) {
        previewError = nil
        let units = DistanceUnits.selected()
        let utterance = VoiceUtterance.kokoroPreview(preset: preset, now: 0, units: units)
        guard let store, utterance.clips.allSatisfy({ store.clipURL(preset: preset, key: $0) != nil }) else {
            previewError = "Voice files are missing. Download them again."
            return
        }
        // With the engine installed the preview says a street name, rendered
        // live, so testers hear exactly what a trip will sound like.
        guard namesStatus == .ready || namesStatus == .tooSlow,
              let sentence = VoiceUtterance.kokoroPreviewSentence(units: units) else {
            navigationController.playKokoroSample(preset)
            return
        }
        previewing = preset.id
        let generation = previewGeneration
        Task {
            let result = await KokoroNameRenderer.shared.renderPreview(text: sentence, preset: preset)
            guard generation == previewGeneration else { return }
            KokoroSupport.record(result, descriptor: store.descriptor)
            switch result {
            case let .rendered(samples, _):
                navigationController.playKokoroSample(preset, firstClip: samples)
            case .failed:
                previewError = "Kokoro couldn't render the preview."
            case .cancelled:
                break
            }
            previewing = nil
            refresh()
        }
    }

    private func downloadModel() {
        modelError = nil
        isDownloadingModel = true
        modelProgress = 0
        KokoroSupport.clearMeasurement()
        Task {
            do {
                try await VoiceModelService().downloadModel { value in
                    Task { @MainActor in modelProgress = value }
                }
            } catch {
                modelError = error.localizedDescription
            }
            isDownloadingModel = false
            refresh()
        }
    }

    private func deleteModel() {
        previewGeneration += 1
        previewing = nil
        KokoroNameRenderer.shared.endPreview()
        KokoroSupport.clearMeasurement()
        do {
            try store?.deleteModel()
        } catch {
            modelError = error.localizedDescription
        }
        refresh()
    }

    private func downloadClips() {
        downloadError = nil
        isDownloading = true
        progress = 0
        Task {
            do {
                try await VoiceModelService().downloadClips { value in
                    Task { @MainActor in progress = value }
                }
            } catch {
                downloadError = error.localizedDescription
            }
            isDownloading = false
            refresh()
        }
    }

    private func deleteAll() {
        engineRaw = VoiceEngine.recorded.rawValue
        previewGeneration += 1
        previewing = nil
        KokoroNameRenderer.shared.endPreview()
        KokoroSupport.clearMeasurement()
        do {
            try store?.delete()
        } catch {
            downloadError = error.localizedDescription
        }
        refresh()
    }
}

// MARK: - Licence Text

/// Shows a licence file bundled under Resources/Licences.
struct LicenceTextView: View {
    let title: String
    let resource: String

    private var text: String {
        Bundle.main.url(forResource: resource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Licence text missing."
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
