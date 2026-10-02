import AppKit

/// Triple-tap ⌃: listens continuously, cuts utterances at 600 ms of silence, and hands each one
/// to the talk pipeline. Pauses while Sidekick is busy or speaking (avoids hearing itself).
@MainActor
final class AlwaysOnListener {
    private let audio = AudioCapture()   // own engine: macOS allows several input clients
    private var segmenter = UtteranceSegmenter()
    private var listenStart: TimeInterval = 0
    private(set) var active = false
    var isBusy: () -> Bool = { false }
    var onUtterance: (([Float]) -> Void)?
    var onChange: ((Bool) -> Void)?

    func toggle() { active ? stop() : start() }

    func start() {
        guard !active else { return }
        do { try audio.start() } catch {
            Log.audio.error("always-on audio failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        active = true
        listenStart = ProcessInfo.processInfo.systemUptime
        segmenter.reset()
        audio.onLevel = { [weak self] level in self?.level(level) }
        onChange?(true)
    }

    func stop() {
        guard active else { return }
        active = false
        audio.stop()
        segmenter.reset()
        onChange?(false)
    }

    private func level(_ l: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if isBusy() { segmenter.reset(); return }
        guard let e = segmenter.feed(level: l, at: now) else { return }
        if case .ended(let start, let end) = e {
            // Pull just this utterance (+300 ms pre-roll) out of the ring buffer.
            let all = audio.peek()
            let seconds = (now - start) + 0.3
            let n = min(all.count, Int(seconds * AudioCapture.sampleRate))
            var clip = Array(all.suffix(n))
            let trailing = Int((now - end) * AudioCapture.sampleRate)
            if trailing > 0, trailing < clip.count { clip.removeLast(trailing) }
            onUtterance?(clip)
        }
    }
}
