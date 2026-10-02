import Foundation

/// Energy-based voice activity helpers. Pure functions, O(n).
enum VAD {
    /// RMS of a buffer.
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// Trims leading/trailing silence using fixed-size frames.
    /// - Parameters:
    ///   - frame: frame size in samples (20 ms at 16 kHz = 320)
    ///   - threshold: RMS below which a frame counts as silence
    ///   - padding: frames of context kept around speech
    static func trimSilence(_ samples: [Float], frame: Int = 320, threshold: Float = 0.01, padding: Int = 10) -> [Float] {
        guard samples.count >= frame else { return samples }
        let frames = samples.count / frame
        var first = -1, last = -1
        for f in 0..<frames {
            let r = rms(samples[(f * frame)..<((f + 1) * frame)])
            if r >= threshold {
                if first < 0 { first = f }
                last = f
            }
        }
        guard first >= 0 else { return [] }
        let start = max(0, first - padding) * frame
        let end = min(samples.count, (last + 1 + padding) * frame)
        return Array(samples[start..<end])
    }
}
