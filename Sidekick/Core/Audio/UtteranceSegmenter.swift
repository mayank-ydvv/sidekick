import Foundation

/// Splits a continuous mic level stream into utterances (always-on mode). Pure; O(1) per sample.
/// Speech starts after `startHold` of level ≥ threshold; ends after `endSilence` below it, or at `maxLength`.
struct UtteranceSegmenter {
    enum Event: Equatable {
        case started(at: TimeInterval)
        case ended(start: TimeInterval, end: TimeInterval)
    }

    var threshold: Float = 0.08
    var startHold: TimeInterval = 0.12
    var endSilence: TimeInterval = 0.6
    var maxLength: TimeInterval = 30
    var minLength: TimeInterval = 0.35

    private var candidateSince: TimeInterval?
    private var speechStart: TimeInterval?
    private var lastVoice: TimeInterval = 0

    var inSpeech: Bool { speechStart != nil }

    mutating func feed(level: Float, at t: TimeInterval) -> Event? {
        let loud = level >= threshold
        if let start = speechStart {
            if loud { lastVoice = t }
            if t - lastVoice >= endSilence || t - start >= maxLength {
                speechStart = nil
                candidateSince = nil
                let end = min(t, lastVoice + 0.15)
                return end - start >= minLength ? .ended(start: start, end: end) : nil
            }
            return nil
        }
        if loud {
            if let c = candidateSince {
                if t - c >= startHold {
                    speechStart = c
                    lastVoice = t
                    return .started(at: c)
                }
            } else {
                candidateSince = t
            }
        } else {
            candidateSince = nil
        }
        return nil
    }

    mutating func reset() { candidateSince = nil; speechStart = nil }
}
