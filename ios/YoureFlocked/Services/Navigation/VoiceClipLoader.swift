import Foundation

struct VoiceClipLoader {
    enum LoadError: Error { case missingClip, liveAudioUnavailable }
    var recordedURL: (PromptVoice, String) -> URL? = { voice, key in voice.url(for: key) }
    var decode: (String, URL) throws -> [Float]

    static func duration(_ clips: [[Float]], sampleRate: Double) -> TimeInterval {
        guard !clips.isEmpty else { return 0 }
        return Double(clips.reduce(0) { $0 + $1.count }) / sampleRate + VoiceTimeline.sentenceGap * Double(clips.count - 1)
    }

    func samples(for utterance: VoiceUtterance) throws -> [[Float]] {
        if let pcm = utterance.renderedPCM, !pcm.isEmpty { return [pcm] }
        guard utterance.liveVoice?.live != true else { throw LoadError.liveAudioUnavailable }
        return try utterance.clips.map { key in
            guard let url = recordedURL(utterance.voice, key) else { throw LoadError.missingClip }
            return try decode("\(utterance.voice.rawValue)/\(key)", url)
        }
    }
}
