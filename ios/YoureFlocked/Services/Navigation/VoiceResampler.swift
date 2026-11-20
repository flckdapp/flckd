@preconcurrency import AVFoundation
import Foundation
import Synchronization

enum VoiceResampler {
    static let outputRate = 44_100.0
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
        let supplied = InputState()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value.withLock({ value in
                if value { return true }
                value = true
                return false
            }) {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private final class InputState: Sendable {
        let value = Mutex(false)
    }
}
