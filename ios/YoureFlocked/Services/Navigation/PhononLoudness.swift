import Foundation

extension VoicePCM {
    /// Mono BS.1770 K-weighting at 44.1 kHz, 400 ms blocks / 100 ms hop,
    /// absolute -70 LUFS and relative -10 LU gates. Short clips are zero-padded
    /// to one block. Used once per voice to calibrate a fixed gain.
    static func evaluationLUFS(_ samples: [Float]) -> Double? {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { return nil }
        let rate = 44_100.0
        let k = tan(.pi * 1681.974450956 / rate) // geo-ok: BS.1770 filter frequency, not a position
        let q = 0.707175236955 // geo-ok: BS.1770 filter Q
        let vh = pow(10.0, 3.999843853973 / 20) // geo-ok: BS.1770 shelf gain
        let vb = pow(vh, 0.499666774155) // geo-ok: BS.1770 shelf exponent
        let a0 = 1 + k / q + k * k
        var shelf = EvaluationBiquad(b0: (vh + vb * k / q + k * k) / a0,
                                    b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                                    a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        let h = tan(.pi * 38.135470876024 / rate) // geo-ok: BS.1770 high-pass frequency
        let hq = 0.500327037324 // geo-ok: BS.1770 high-pass Q
        let h0 = 1 + h / hq + h * h
        var highpass = EvaluationBiquad(b0: 1, b1: -2, b2: 1,
                                       a1: 2 * (h * h - 1) / h0, a2: (1 - h / hq + h * h) / h0)
        let block = Int(rate * 0.4), hop = Int(rate * 0.1)
        var energy = [Double](repeating: 0, count: max(block, samples.count))
        for index in energy.indices {
            let input = index < samples.count ? Double(samples[index]) : 0
            let weighted = highpass.process(shelf.process(input))
            energy[index] = weighted * weighted
        }
        func lufs(_ value: Double) -> Double { -0.691 + 10 * log10(max(value, .leastNonzeroMagnitude)) }
        var blocks: [Double] = []
        for start in stride(from: 0, through: energy.count - block, by: hop) {
            let value = energy[start..<(start + block)].reduce(0, +) / Double(block)
            if lufs(value) >= -70 { blocks.append(value) }
        }
        guard !blocks.isEmpty else { return nil }
        let relative = lufs(blocks.reduce(0, +) / Double(blocks.count)) - 10
        let gated = blocks.filter { lufs($0) >= relative }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

private struct EvaluationBiquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
