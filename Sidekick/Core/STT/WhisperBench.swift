#if DEBUG
import AVFoundation
import AppKit

/// Debug-only: `Sidekick -benchWhisper /path/to/audio` loads the model, transcribes 3×, prints timings, quits.
enum WhisperBench {
    @MainActor
    static func run(path: String, model: WhisperModel, stt: WhisperKitSTT) async {
        let t0 = ProcessInfo.processInfo.systemUptime
        await stt.load(model) { _ in }
        let loadMs = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        print("BENCH model=\(model.rawValue) load+warm=\(loadMs)ms")
        guard let samples = try? load16k(URL(fileURLWithPath: path)) else {
            print("BENCH could not read audio"); NSApp.terminate(nil); return
        }
        let trimmed = VAD.trimSilence(samples)
        print("BENCH audio=\(samples.count / 16)ms trimmed=\(trimmed.count / 16)ms")
        for i in 1...3 {
            let s = ProcessInfo.processInfo.systemUptime
            let text = (try? await stt.transcribe(trimmed, language: nil, prompt: nil)) ?? "<error>"
            print("BENCH run\(i) \(Int((ProcessInfo.processInfo.systemUptime - s) * 1000))ms text=\"\(text)\"")
        }
        let rss = residentMB()
        print("BENCH rss=\(rss)MB")
        NSApp.terminate(nil)
    }

    static func load16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        let conv = AVAudioConverter(from: file.processingFormat, to: target)!
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate + 64)
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
        var done = false
        conv.convert(to: out, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}
#endif
