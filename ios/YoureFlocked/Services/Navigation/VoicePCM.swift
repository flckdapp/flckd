import Foundation

/// Float PCM processing shared by the player and the gap measurement tests.
enum VoicePCM {
    static let silenceThreshold: Float = 0.0001

    static func trimmed(_ samples: [Float]) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) > silenceThreshold }),
              let last = samples.lastIndex(where: { abs($0) > silenceThreshold }) else { return [] }
        return Array(samples[first...last])
    }

    static func compose(_ clips: [[Float]], sampleRate: Double) -> [Float] {
        let segments = VoiceTimeline.segments(lengths: clips.map(\.count), sampleRate: sampleRate)
        guard let last = segments.last else { return [] }
        var result = [Float](repeating: 0, count: last.startFrame + last.frameCount)
        let fade = max(1, Int(sampleRate * VoiceTimeline.fadeDuration))
        for segment in segments {
            let samples = clips[segment.clipIndex]
            for index in samples.indices {
                let gain = min(1, Float(min(index, samples.count - 1 - index)) / Float(fade))
                result[segment.startFrame + index] = samples[index] * gain
            }
        }
        return result
    }

    /// Applies a gain in dB, then a look-ahead peak limiter so no sample
    /// exceeds `ceiling`: 1 ms attack and 50 ms release, the settings
    /// `scripts/voice-prompts/normalize.py` levels the recorded clips with.
    static func applyGain(_ samples: [Float], db: Double, ceiling: Float = 0.66, sampleRate: Double = 44_100) -> [Float] {
        let gain = Float(pow(10, db / 20))
        let scaled = samples.map { $0 * gain }
        guard let peak = scaled.map(abs).max(), peak > ceiling else { return scaled }
        var envelope = scaled.map { abs($0) > ceiling ? ceiling / abs($0) : 1 }
        let attackStep = 1 / Float(max(1, Int(sampleRate * 0.001)))
        let releaseStep = 1 / Float(max(1, Int(sampleRate * 0.050)))
        if envelope.count > 1 {
            for index in stride(from: envelope.count - 2, through: 0, by: -1) {
                envelope[index] = min(envelope[index], envelope[index + 1] + attackStep)
            }
            for index in 1..<envelope.count {
                envelope[index] = min(envelope[index], envelope[index - 1] + releaseStep)
            }
        }
        return zip(scaled, envelope).map { $0 * $1 }
    }
}

