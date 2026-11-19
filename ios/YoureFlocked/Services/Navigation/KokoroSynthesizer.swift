@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import SherpaOnnx

/// One speech engine instance. Not thread-safe: `KokoroSynthesizer` confines it
/// to its queue.
protocol KokoroEngine: AnyObject {
    func generate(text: String, sid: Int) -> (samples: [Float], sampleRate: Int)?
}

/// sherpa-onnx's Kokoro on the CPU. `debug` stays 0; even so the engine logs
/// unknown words, which is why only checked text reaches it (see `SpokenText`).
final class SherpaKokoroEngine: KokoroEngine {
    private let tts: SherpaOnnxOfflineTtsWrapper

    init?(paths: KokoroVoiceStore.ModelPaths, threads: Int = 2) {
        let wrapper: SherpaOnnxOfflineTtsWrapper = autoreleasepool {
            let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: paths.model, voices: paths.voices, tokens: paths.tokens, lexicon: paths.lexicon)
            let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: threads, debug: 0, provider: "cpu")
            var config = sherpaOnnxOfflineTtsConfig(model: model)
            return SherpaOnnxOfflineTtsWrapper(config: &config)
        }
        guard wrapper.tts != nil else { return nil }
        tts = wrapper
    }

    func generate(text: String, sid: Int) -> (samples: [Float], sampleRate: Int)? {
        let audio = tts.generate(text: text, sid: sid, speed: 1.0)
        let samples = audio.samples
        guard !samples.isEmpty, audio.sampleRate > 0 else { return nil }
        return (samples, Int(audio.sampleRate))
    }
}

/// Owns the engine on its own serial queue. Every method marked "on queue"
/// must run there; the name renderer dispatches its work onto `queue`.
/// No text is ever logged or written down.
final class KokoroSynthesizer: @unchecked Sendable {
    typealias Factory = @Sendable () -> (engine: KokoroEngine, lexicon: KokoroLexicon)?

    static let log = Logger(subsystem: "io.vws.app.flckd", category: "kokoro")
    static let outputRate = 44_100.0

    let queue = DispatchQueue(label: "app.flckd.kokoro", qos: .utility)
    private let factory: Factory
    private var engine: KokoroEngine?
    private(set) var lexicon: KokoroLexicon?

    static let standardFactory: Factory = {
        guard let paths = KokoroVoiceStore.standard?.modelPaths(),
              let lexicon = KokoroLexicon(contentsOfFile: paths.lexicon),
              let engine = SherpaKokoroEngine(paths: paths) else { return nil }
        return (engine, lexicon)
    }

    init(factory: @escaping Factory = KokoroSynthesizer.standardFactory) {
        self.factory = factory
    }

    /// On queue. Loads the engine and its word list if they are not loaded.
    @discardableResult
    func loadOnQueue() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if engine != nil { return true }
        guard let loaded = factory() else {
            Self.log.error("Kokoro engine could not load")
            return false
        }
        engine = loaded.engine
        lexicon = loaded.lexicon
        return true
    }

    /// On queue.
    func unloadOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        engine = nil
        lexicon = nil
    }

    /// On queue.
    var isLoaded: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return engine != nil
    }

    func load() { queue.async { self.loadOnQueue() } }
    func unload() { queue.async { self.unloadOnQueue() } }

    /// On queue. Returns 44.1 kHz mono floats, trimmed and levelled with the
    /// preset's gain, plus render time divided by audio duration. Text that
    /// fails the word check never reaches the engine.
    func render(_ text: String, preset: KokoroPreset, knows: (String) -> Bool) -> (samples: [Float], rtf: Double)? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard SpokenText.isSpeakable(text, knows: knows), let engine else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        guard let output = engine.generate(text: text, sid: preset.sid) else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let duration = Double(output.samples.count) / Double(output.sampleRate)
        guard duration > 0 else { return nil }
        let resampled = Self.resample(output.samples, from: Double(output.sampleRate), to: Self.outputRate)
        let samples = VoicePCM.applyGain(VoicePCM.trimmed(resampled), db: preset.gainDB)
        guard !samples.isEmpty else { return nil }
        return (samples, elapsed / duration)
    }

    /// Mono float sample-rate conversion.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard source != target, !samples.isEmpty else { return samples }
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { input.floatChannelData?[0].update(from: base, count: source.count) }
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * target / source) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
