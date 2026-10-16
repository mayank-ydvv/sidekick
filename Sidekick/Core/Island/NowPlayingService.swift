import AppKit
import Observation

/// What's playing in any app (Music, Spotify, YouTube in a browser…). macOS only lets Apple-signed processes read
/// MediaRemote, so a tiny helper (NowPlayingAdapter.dylib) runs inside the system perl and streams JSON lines.
@MainActor
@Observable
final class NowPlayingService {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        /// Elapsed time at `updated`, and the playback rate since then (0 when paused).
        var elapsed: TimeInterval
        var updated: Date
        var rate: Double
        var playing: Bool
        var bundleID: String?
        var artwork: NSImage?
        /// Dominant artwork colour, used to tint the waveform like iPhone.
        var tint: NSColor

        func position(at now: Date = Date()) -> TimeInterval {
            let p = elapsed + (playing ? now.timeIntervalSince(updated) * max(rate, playing ? 1 : 0) : 0)
            return duration > 0 ? min(max(0, p), duration) : max(0, p)
        }

        static func == (a: Track, b: Track) -> Bool {
            a.title == b.title && a.artist == b.artist && a.playing == b.playing && a.elapsed == b.elapsed
                && a.bundleID == b.bundleID && (a.artwork == nil) == (b.artwork == nil)
        }
    }

    private(set) var track: Track?
    /// Music shows in the closed notch while playing, and for 10 s after pausing.
    private(set) var showInClosedNotch = false

    private var process: Process?
    private var buffer = Data()
    private var restarts = 0
    private var stopped = true
    private var pausedWork: DispatchWorkItem?
    private var lastArtworkKey = ""

    static var helperDylib: URL? { Bundle.main.url(forResource: "NowPlayingAdapter", withExtension: "dylib") }
    static var helperScript: URL? { Bundle.main.url(forResource: "nowplaying", withExtension: "pl") }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    // MARK: Commands

    enum Command: String { case toggle, play, pause, next, previous }

    func send(_ c: Command) { run(command: c.rawValue) }

    func seek(to seconds: TimeInterval) { run(command: "seek:\(max(0, seconds))") }

    /// Optimistic UI: flip play/pause immediately; the stream confirms a moment later.
    func togglePlayPause() {
        if var t = track {
            t.elapsed = t.position(); t.updated = Date(); t.playing.toggle()
            track = t
            updateClosedVisibility()
        }
        send(.toggle)
    }

    func openSourceApp() {
        guard let id = track?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func run(command: String) {
        guard let dylib = Self.helperDylib, let script = Self.helperScript else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, dylib.path, "send"]
        p.environment = ["SIDEKICK_MR_CMD": command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Stream

    private func launch() {
        guard !stopped, process == nil, let dylib = Self.helperDylib, let script = Self.helperScript else {
            if Self.helperDylib == nil { Log.app.error("now playing helper missing from the app bundle") }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, dylib.path, "stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = Pipe()   // the helper exits when this closes (i.e. when Sidekick quits)
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.helperExited() } }
        }
        do {
            try p.run()
            process = p
        } catch {
            Log.app.error("now playing helper failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func helperExited() {
        process = nil
        guard !stopped else { return }
        restarts += 1
        // Back off if it keeps crashing (e.g. a macOS update changed MediaRemote).
        let delay = min(300, pow(2, Double(min(restarts, 8))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(json) }
        }
    }

    func apply(_ j: [String: Any]) {
        if j["error"] != nil { return }
        restarts = 0
        let title = (j["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            if track != nil { track = nil; updateClosedVisibility() }
            return
        }
        let artist = j["artist"] as? String ?? ""
        var art = track?.artwork
        var tint = track?.tint ?? .white
        let artKey = title + artist
        if let b64 = j["artwork"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d) {
            art = img
            tint = Self.dominantColor(img)
            lastArtworkKey = artKey
        } else if artKey != lastArtworkKey {
            art = nil
            tint = .white
        }
        let ts = (j["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let playing = (j["playing"] as? Bool) ?? ((j["playing"] as? Int) == 1)
        track = Track(title: title, artist: artist, album: j["album"] as? String ?? "",
                      duration: j["duration"] as? Double ?? 0, elapsed: j["elapsed"] as? Double ?? 0,
                      updated: ts, rate: j["rate"] as? Double ?? (playing ? 1 : 0), playing: playing,
                      bundleID: j["bundle"] as? String, artwork: art, tint: tint)
        updateClosedVisibility()
    }

    private func updateClosedVisibility() {
        pausedWork?.cancel()
        guard let t = track else { showInClosedNotch = false; return }
        if t.playing { showInClosedNotch = true; return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.track?.playing != true else { return }
            self.showInClosedNotch = false
        }
        pausedWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }

    /// Average colour of the artwork (8×8 downsample), brightened so it reads on black.
    static func dominantColor(_ img: NSImage) -> NSColor {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let ctx = CGContext(data: &px, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]) }
        let n = 64.0 * 255
        let c = NSColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.2), brightness: max(0.75, v), alpha: 1)
    }
}
