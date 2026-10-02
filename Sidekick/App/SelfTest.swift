import AppKit
import AVFoundation
import QuartzCore

/// `Sidekick -selfTest YES`: measures the spec §3 numbers in the real (Release) app and prints a report.
/// Notch animation pacing is measured with a display link: a late frame means the main thread was busy.
@MainActor
enum SelfTest {
    static func run(env: AppEnvironment) async {
        var report: [String: String] = [:]
        let t0 = ProcessInfo.processInfo.systemUptime
        env.launch()

        // 1) Whisper load + warm, then STT latency on a synthesized ~5 s clip.
        while true {
            if case .ready = env.state.whisper { break }
            if case .failed(let m) = env.state.whisper { report["whisper"] = "failed: \(m)"; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        report["launch→whisper ready (ms)"] = "\(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000))"
        if let clip = await synthesize("Hey Sidekick, can you tell me what is on my screen right now and where the export button is?") {
            var times: [Int] = []
            for _ in 0..<3 {
                let s = ProcessInfo.processInfo.systemUptime
                _ = try? await env.stt.transcribe(VAD.trimSilence(clip), language: nil, prompt: nil)
                times.append(Int((ProcessInfo.processInfo.systemUptime - s) * 1000))
            }
            report["whisper \(clip.count / 16) ms clip (ms, 3 runs)"] = times.map(String.init).joined(separator: " / ")
        }

        // 2) Screenshot capture latency (needs Screen Recording).
        if CGPreflightScreenCaptureAccess() {
            var times: [Int] = []
            for _ in 0..<5 {
                let s = ProcessInfo.processInfo.systemUptime
                _ = try? await env.capturer.capture(readBrowserURL: false)
                times.append(Int((ProcessInfo.processInfo.systemUptime - s) * 1000))
            }
            report["screenshot capture (ms, 5 runs)"] = times.map(String.init).joined(separator: " / ")
        } else {
            report["screenshot capture"] = "skipped (no screen recording permission)"
        }

        // 3) Notch morph frame pacing over 4 open/close cycles.
        let pacer = FramePacer()
        pacer.start()
        for _ in 0..<4 {
            env.notch.open(.compact)
            try? await Task.sleep(nanoseconds: 700_000_000)
            env.notch.close()
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        let p = pacer.stop()
        report["notch morph fps (avg)"] = String(format: "%.1f", p.fps)
        report["notch morph long frames (>1.5× interval)"] = "\(p.longFrames) of \(p.frames)"

        // 4) Idle CPU + RAM after settling.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let c0 = cpuTime(), w0 = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let cpu = (cpuTime() - c0) / (ProcessInfo.processInfo.systemUptime - w0) * 100
        report["idle CPU (%)"] = String(format: "%.2f", cpu)
        report["RSS (MB)"] = "\(residentMB())"

        print("SELFTEST BEGIN")
        for (k, v) in report.sorted(by: { $0.key < $1.key }) { print("SELFTEST \(k): \(v)") }
        print("SELFTEST END")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// Speaks text into a 16 kHz mono buffer with the system voice (no files).
    static func synthesize(_ text: String) async -> [Float]? {
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        var buffers: [AVAudioPCMBuffer] = []
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            synth.write(u) { buf in
                guard let pcm = buf as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !done { done = true; cont.resume() }
                } else {
                    buffers.append(pcm)
                }
            }
        }
        guard let fmt = buffers.first?.format else { return nil }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: fmt, to: target) else { return nil }
        var out: [Float] = []
        for b in buffers {
            let cap = AVAudioFrameCount(Double(b.frameLength) * 16_000 / fmt.sampleRate + 64)
            guard let o = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { continue }
            var fed = false
            conv.convert(to: o, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return b
            }
            if let ch = o.floatChannelData?[0] { out += UnsafeBufferPointer(start: ch, count: Int(o.frameLength)) }
        }
        return out
    }

    static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
             + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}

/// Collects display-link frame intervals on the main thread.
@MainActor
final class FramePacer: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var interval: CFTimeInterval = 1.0 / 60

    func start() {
        guard let screen = NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        stamps.append(l.timestamp)
        interval = l.duration > 0 ? l.duration : interval
    }

    func stop() -> (fps: Double, longFrames: Int, frames: Int) {
        link?.invalidate()
        link = nil
        guard stamps.count > 2 else { return (0, 0, 0) }
        let deltas = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let long = deltas.filter { $0 > interval * 1.5 }.count
        let fps = Double(deltas.count) / deltas.reduce(0, +)
        return (fps, long, deltas.count)
    }
}
