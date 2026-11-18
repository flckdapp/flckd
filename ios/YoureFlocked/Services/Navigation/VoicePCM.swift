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
}
