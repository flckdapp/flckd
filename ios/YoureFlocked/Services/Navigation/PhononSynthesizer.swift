import Foundation
import PhononTTS
import Synchronization

protocol SpeechSynthesizing: Sendable {
    func load() async throws -> PhononSynthesizer.Load
    func render(_ text: String, voice: String) async throws -> PhononSynthesizer.Render
}

/// The actor owns the instance; Phonon serializes C calls on
/// its own user-initiated queue. No input text or engine error is logged.
actor PhononSynthesizer: SpeechSynthesizing {
    struct Load: Sendable {
        let seconds: Double
        let compiled: Bool
        let voices: [String]
    }

    struct Render: Sendable {
        let samples: [Float]
        let seconds: Double
        let firstAudio: Double
        let rtf: Double
        let peakBytes: UInt64
        let gainDB: Double
        let lufs: Double
    }

    enum Failure: Error { case missingModels, invalidText, busy, emptyAudio, unknownVoice }
    private let native = PhononNative()
    private var voices: [String]?
    private var busy = false
    private var gains: [String: Double] = [:]

    func load() async throws -> Load {
        try Task.checkCancellation()
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        return try await loadEngine()
    }

    private func loadEngine() async throws -> Load {
        try Task.checkCancellation()
        if let voices { return Load(seconds: 0, compiled: false, voices: voices) }
        guard let bundled = Bundle.main.url(forResource: "Models", withExtension: nil) else {
            throw Failure.missingModels
        }
        let start = ProcessInfo.processInfo.systemUptime
        let authorization = SpeechLoadAuthorization.shared
        let grant = try await authorization.grant()
        try authorization.check(grant)
        let instance = try await native.load(bundle: bundled, authorization: authorization, grant: grant)
        try Task.checkCancellation()
        // Calibrate once per loaded voice with the same long generic passage,
        // never a short turn/name. The fixed gain then applies to all requests.
        for voice in PhononSentences.voices where gains[voice] == nil {
            try authorization.check(grant)
            try await native.setVoice(voice)
            var raw: [Float] = []
            for sentence in PhononSentences.split("In a quarter mile, turn right. Continue on this road for one mile. Flock camera ahead. You have arrived.") {
                try Task.checkCancellation()
                try authorization.check(grant)
                raw += try await native.audio(sentence).samples
            }
            let pcm = VoicePCM.trimmed(VoiceResampler.resample(raw, from: Phonon.sampleRate, to: VoiceResampler.outputRate))
            guard let lufs = VoicePCM.evaluationLUFS(pcm) else { throw Failure.emptyAudio }
            gains[voice] = -16 - lufs
        }
        try authorization.check(grant)
        voices = instance.voices
        return Load(seconds: ProcessInfo.processInfo.systemUptime - start, compiled: instance.compiled, voices: instance.voices)
    }

    var isLoaded: Bool { voices != nil }

    func unload() async throws {
        guard !busy else { throw Failure.busy }
        await native.unload()
        voices = nil
    }

    func render(_ text: String, voice: String) async throws -> Render {
        guard PhononSentences.accepts(text) else { throw Failure.invalidText }
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        // Only explicit foreground warm-up may load/compile.
        guard voices != nil else { throw Failure.missingModels }
        try Task.checkCancellation()
        guard let voices else { throw Failure.missingModels }
        guard PhononSentences.voices.contains(voice), voices.contains(voice) else { throw Failure.unknownVoice }
        try await native.setVoice(voice)
        #if DEBUG
        let peak = Mutex(VoiceDiagnostics.footprint() ?? 0)
        let sampler = Task.detached {
            while !Task.isCancelled {
                let bytes = VoiceDiagnostics.footprint() ?? 0
                peak.withLock { $0 = max($0, bytes) }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
        }
        defer { sampler.cancel() }
        #endif
        let start = ProcessInfo.processInfo.systemUptime
        var clips: [[Float]] = []
        var firstAudio = 0.0
        var audioSeconds = 0.0
        for sentence in PhononSentences.split(text.precomposedStringWithCanonicalMapping) {
            try Task.checkCancellation()
            let audio = try await native.audio(sentence)
            if clips.isEmpty { firstAudio = audio.first }
            audioSeconds += audio.seconds
            let raw = audio.samples
            let resampled = VoiceResampler.resample(raw, from: Phonon.sampleRate, to: VoiceResampler.outputRate)
            let trimmed = VoicePCM.trimmed(resampled)
            guard !trimmed.isEmpty else { throw Failure.emptyAudio }
            clips.append(trimmed)
        }
        try Task.checkCancellation()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        guard !clips.isEmpty, let gain = gains[voice] else { throw Failure.emptyAudio }
        // Compose uses VoiceTimeline.sentenceGap and endpoint fades. Only this
        // utterance is joined; ordinary prompt scheduling is untouched.
        let samples = VoicePCM.compose(clips.map { VoicePCM.applyGain($0, db: gain) }, sampleRate: VoiceResampler.outputRate)
        #if DEBUG
        let measuredPeak = peak.withLock { $0 }
        let measuredLUFS = VoicePCM.evaluationLUFS(samples) ?? 0
        #else
        let measuredPeak: UInt64 = 0
        let measuredLUFS = 0.0
        #endif
        return Render(samples: samples, seconds: seconds,
                      firstAudio: firstAudio,
                      rtf: audioSeconds > 0 ? seconds / audioSeconds : 0,
                      peakBytes: measuredPeak, gainDB: gain,
                      lufs: measuredLUFS)
    }
}
