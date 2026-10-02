import AVFoundation
import os

/// Microphone capture → 16 kHz mono Float32 into a pre-allocated ring buffer.
/// Not an actor: the audio tap runs on a realtime thread and can't await,
/// so the buffer is guarded by an unfair lock instead (see DECISIONS.md).
final class AudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let maxSeconds: Double = 120

    /// Called on the main queue ~30×/s with the current RMS level (0…1).
    var onLevel: (@MainActor (Float) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let lock = OSAllocatedUnfairLock(initialState: RingBuffer(capacity: Int(sampleRate * maxSeconds)))
    private var lastLevelTime: TimeInterval = 0
    private(set) var isRunning = false
    private var configObserver: NSObjectProtocol?
    /// Called (main queue) when the input device changed and capture restarted — or failed to.
    var onDeviceChange: ((Bool) -> Void)?

    func start() throws {
        guard !isRunning else { return }
        lock.withLock { $0.reset() }
        try installTapAndStart()
        isRunning = true
        if configObserver == nil {
            // The engine stops itself when the input device or its format changes; restart on the new device.
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.deviceChanged()
            }
        }
    }

    /// UI tests: behave as if the input device just changed.
    func simulateDeviceChange() { deviceChanged() }

    private func deviceChanged() {
        guard isRunning else { return }
        Log.audio.notice("input device changed; restarting capture")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTapAndStart()   // keeps what was recorded so far in the ring buffer
            onDeviceChange?(true)
        } catch {
            isRunning = false
            Log.audio.error("restart after device change failed: \(error.localizedDescription, privacy: .public)")
            onDeviceChange?(false)
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }
        if converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: targetFormat)
            converterInputFormat = inFormat
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns everything recorded since `start()`.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        return lock.withLock { $0.snapshot() }
    }

    /// Current buffer contents without stopping (always-on mode).
    func peek() -> [Float] {
        lock.withLock { $0.snapshot() }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let ptr = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
        lock.withLockUnchecked { $0.append(ptr) }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelTime >= 1.0 / 30.0, let onLevel {
            lastLevelTime = now
            // Map RMS to a perceptual 0…1 range.
            let level = min(1, VAD.rms(ptr) * 12)
            DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(level) } }
        }
    }

    enum AudioError: LocalizedError {
        case noInputDevice
        var errorDescription: String? { "no microphone found" }
    }
}
