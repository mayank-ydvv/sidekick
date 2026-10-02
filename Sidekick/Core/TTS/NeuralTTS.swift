import AVFoundation
import SherpaOnnx

/// A loaded sherpa-onnx voice model. Only touched on `NeuralTTS.queue`.
final class NeuralVoiceModel: @unchecked Sendable {
    private let tts: OpaquePointer
    let sampleRate: Double
    let speakers: Int

    private init?(_ make: (inout SherpaOnnxOfflineTtsConfig, CStrings) -> Void) {
        let strings = CStrings()
        defer { strings.free() }
        var c = SherpaOnnxOfflineTtsConfig()
        c.model.num_threads = 4
        c.model.provider = strings["cpu"]
        c.max_num_sentences = 1
        make(&c, strings)
        guard let p = SherpaOnnxCreateOfflineTts(&c) else { return nil }
        tts = p
        sampleRate = Double(SherpaOnnxOfflineTtsSampleRate(p))
        speakers = Int(SherpaOnnxOfflineTtsNumSpeakers(p))
    }

    /// Kokoro (English): warm, natural voices such as "af_heart".
    static func kokoro(at dir: URL) -> NeuralVoiceModel? {
        NeuralVoiceModel { c, s in
            let f = { (n: String) in s[dir.appendingPathComponent(n).path] }
            c.model.kokoro.model = f("model.onnx")
            c.model.kokoro.voices = f("voices.bin")
            c.model.kokoro.tokens = f("tokens.txt")
            c.model.kokoro.data_dir = f("espeak-ng-data")
            c.model.kokoro.dict_dir = f("dict")
            c.model.kokoro.lexicon = s[dir.appendingPathComponent("lexicon-us-en.txt").path + "," + dir.appendingPathComponent("lexicon-zh.txt").path]
            c.model.kokoro.length_scale = 1.0
        }
    }

    /// Piper VITS (Hindi): "priyamvada", a soft Indian female voice.
    static func piper(at dir: URL, model: String) -> NeuralVoiceModel? {
        NeuralVoiceModel { c, s in
            let f = { (n: String) in s[dir.appendingPathComponent(n).path] }
            c.model.vits.model = f(model)
            c.model.vits.tokens = f("tokens.txt")
            c.model.vits.data_dir = f("espeak-ng-data")
            c.model.vits.noise_scale = 0.667
            c.model.vits.noise_scale_w = 0.8
            c.model.vits.length_scale = 1.0
        }
    }

    func generate(_ text: String, sid: Int, speed: Float) -> [Float] {
        var g = SherpaOnnxGenerationConfig()
        g.sid = Int32(max(0, min(sid, speakers - 1)))
        g.speed = speed
        g.silence_scale = 0.2
        guard let audio = text.withCString({ SherpaOnnxOfflineTtsGenerateWithConfig(tts, $0, &g, nil, nil) }) else { return [] }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let a = audio.pointee
        guard a.n > 0, let p = a.samples else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(a.n)))
    }

    deinit { SherpaOnnxDestroyOfflineTts(tts) }

    /// Keeps C strings alive for the duration of model creation.
    final class CStrings {
        private var ptrs: [UnsafeMutablePointer<CChar>] = []
        subscript(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            ptrs.append(p)
            return UnsafePointer(p)
        }
        func free() { ptrs.forEach { Foundation.free($0) }; ptrs = [] }
    }
}

/// Soft, natural offline voices (Kokoro for English, Piper for Hindi), synthesized a sentence at a time
/// on a background queue and played gaplessly. `stop()` is instant. Falls back (via `SpeechOutput`) when
/// the models aren't installed or fail to load.
@MainActor
final class NeuralTTS {
    struct VoiceOption: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let label: String
        let sid: Int
    }

    /// Soft female Kokoro voices (speaker ids of kokoro-multi-lang-v1_0).
    static let voices: [VoiceOption] = [
        .init(name: "af_heart", label: "Heart — warm & soft", sid: 3),
        .init(name: "af_bella", label: "Bella — gentle, expressive", sid: 2),
        .init(name: "af_nicole", label: "Nicole — breathy, calm", sid: 6),
        .init(name: "af_sky", label: "Sky — light & airy", sid: 10),
        .init(name: "af_sarah", label: "Sarah — clear & friendly", sid: 9),
        .init(name: "af_aoede", label: "Aoede — smooth", sid: 1),
        .init(name: "bf_emma", label: "Emma — soft British", sid: 21),
        .init(name: "bf_lily", label: "Lily — light British", sid: 23),
    ]
    nonisolated static let defaultVoice = "af_heart"

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekick/Voices", isDirectory: true)
    }
    nonisolated static var kokoroDir: URL { folder.appendingPathComponent("kokoro-multi-lang-v1_0", isDirectory: true) }
    nonisolated static var hindiDir: URL { folder.appendingPathComponent("vits-piper-hi_IN-priyamvada-medium", isDirectory: true) }
    nonisolated static let hindiModel = "hi_IN-priyamvada-medium.onnx"

    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: kokoroDir.appendingPathComponent("model.onnx").path)
    }
    nonisolated static var hindiInstalled: Bool {
        FileManager.default.fileExists(atPath: hindiDir.appendingPathComponent(hindiModel).path)
    }

    var onFirstAudio: (() -> Void)?
    var onFinished: (() -> Void)?
    var voice = defaultVoice
    /// 1 = normal speed.
    var speed: Float = 1.0
    var volume: Float = 1.0 { didSet { players.values.forEach { $0.volume = volume } } }
    /// The English model can't load (permanent) or audio output failed this reply; `SpeechOutput` then uses the Mac voice.
    var failed: Bool { modelFailed || audioFailed }
    private var modelFailed = false
    private var audioFailed = false

    private let queue = DispatchQueue(label: "sidekick.neural-tts", qos: .userInitiated)
    private let models = Models()
    private let engine = AVAudioEngine()
    private var players: [Double: AVAudioPlayerNode] = [:]
    private var generation = 0
    private var pending = 0
    private var started = false
    /// Hindi (Devanagari) replies use the Hindi voice; decided once per reply so it never switches mid-answer.
    private var replyHindi: Bool?
    private var idleStop: DispatchWorkItem?
    private var unloadWork: DispatchWorkItem?
    /// The voice model (~450 MB) is freed after this long without speech, and reloaded when the user starts talking.
    static var unloadAfter: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "voiceUnloadAfter")   // hidden, for testing
        return v > 0 ? v : 600
    }

    var isSpeaking: Bool { pending > 0 }

    init() {
        // Headphones/speakers changed: the engine stops and its graph is rebuilt; drop our players and
        // recreate them on the next sentence (otherwise the voice would go silent or fall back for good).
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioRouteChanged() }
        }
    }

    private func audioRouteChanged() {
        Log.app.info("audio output changed; rebuilding the voice player")
        let wasSpeaking = pending > 0
        players.values.forEach { $0.stop(); engine.detach($0) }
        players = [:]
        if wasSpeaking { stop(); onFinished?() }
    }

    /// Loads the English model and runs a tiny synthesis so the first real reply starts fast.
    func prewarm() {
        let models = models
        unloadWork?.cancel()
        queue.async {
            guard !models.englishLoaded, let m = models.english() else { return }
            _ = m.generate("Hi.", sid: 3, speed: 1)
            Log.app.info("neural voice ready (\(m.speakers) voices)")
        }
        if pending == 0 { scheduleUnload() }
    }

    func beginReply() {
        replyHindi = nil
        audioFailed = false   // an audio-device hiccup shouldn't switch to the Mac voice for good
    }

    func enqueue(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if replyHindi == nil {
            replyHindi = Self.hindiInstalled && text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        }
        let hindi = replyHindi ?? false
        let sid = Self.voices.first { $0.name == voice }?.sid ?? 3
        let speed = speed
        let gen = generation
        let models = models
        pending += 1
        idleStop?.cancel()
        unloadWork?.cancel()
        queue.async { [weak self] in
            let model = hindi ? (models.hindi() ?? models.english()) : models.english()
            let samples = model?.generate(text, sid: sid, speed: speed) ?? []
            let rate = model?.sampleRate ?? 24_000
            let loadFailed = model == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.play(samples, rate: rate, gen: gen, loadFailed: loadFailed) }
            }
        }
    }

    func stop() {
        generation += 1
        pending = 0
        started = false
        replyHindi = nil
        players.values.forEach { $0.stop() }
    }

    // MARK: Playback

    private func play(_ samples: [Float], rate: Double, gen: Int, loadFailed: Bool) {
        guard gen == generation else { return }
        if loadFailed { modelFailed = true }
        guard !samples.isEmpty, let player = player(for: rate),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return finishedOne(gen)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                Log.app.error("neural voice audio: \(error.localizedDescription, privacy: .public)")
                audioFailed = true
                return finishedOne(gen)
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishedOne(gen) } }
        }
        if !player.isPlaying { player.play() }
        if !started {
            started = true
            onFirstAudio?()
        }
    }

    private func finishedOne(_ gen: Int) {
        guard gen == generation, pending > 0 else { return }
        pending -= 1
        guard pending == 0 else { return }
        started = false
        onFinished?()
        // Release the audio device when quiet for a while.
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.pending == 0 else { return }
            self.engine.pause()
        }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        scheduleUnload()
    }

    private func scheduleUnload() {
        unloadWork?.cancel()
        let models = models, queue = queue
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.pending == 0 else { return }
            queue.async { models.unloadEnglish() }
            Log.app.info("natural voice unloaded after idle")
        }
        unloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unloadAfter, execute: w)
    }

    private func player(for rate: Double) -> AVAudioPlayerNode? {
        if let p = players[rate] { return p }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
        let p = AVAudioPlayerNode()
        p.volume = volume
        engine.attach(p)
        engine.connect(p, to: engine.mainMixerNode, format: format)
        players[rate] = p
        return p
    }

    /// Lazily loaded models (queue-confined).
    private final class Models: @unchecked Sendable {
        private var en: NeuralVoiceModel?
        private var hi: NeuralVoiceModel?
        private var enTried = false, hiTried = false

        /// Frees the English model (it reloads on next use). Only after a successful load, so failures stay remembered.
        func unloadEnglish() {
            guard en != nil else { return }
            en = nil
            enTried = false
        }

        var englishLoaded: Bool { en != nil }

        func english() -> NeuralVoiceModel? {
            if !enTried {
                enTried = true
                en = NeuralVoiceModel.kokoro(at: NeuralTTS.kokoroDir)
                if en == nil { Log.app.error("couldn't load the Kokoro voice") }
            }
            return en
        }

        func hindi() -> NeuralVoiceModel? {
            if !hiTried {
                hiTried = true
                hi = NeuralVoiceModel.piper(at: NeuralTTS.hindiDir, model: NeuralTTS.hindiModel)
                if hi == nil { Log.app.error("couldn't load the Hindi voice") }
            }
            return hi
        }
    }
}

/// Picks the natural voice when it's installed and enabled, otherwise the Mac's built-in voice.
@MainActor
final class SpeechOutput {
    let system = SystemTTS()
    let neural = NeuralTTS()
    var useNatural = true

    var onFirstAudio: (() -> Void)? {
        didSet { system.onFirstAudio = onFirstAudio; neural.onFirstAudio = onFirstAudio }
    }
    var onFinished: (() -> Void)? {
        didSet { system.onFinished = onFinished; neural.onFinished = onFinished }
    }

    private var natural: Bool { useNatural && NeuralTTS.isInstalled && !neural.failed }
    var isSpeaking: Bool { system.isSpeaking || neural.isSpeaking }

    func apply(_ d: SettingsData) {
        useNatural = d.naturalVoice
        neural.voice = d.naturalVoiceName
        // AVSpeech's ~0.5 is normal speed.
        neural.speed = max(0.7, min(1.4, d.ttsRate / 0.5))
        neural.volume = d.ttsVolume
        system.voiceIdentifier = d.ttsVoiceID
        system.rate = d.ttsRate
        system.pitch = d.ttsPitch
        system.volume = d.ttsVolume
    }

    func prewarm() {
        system.prewarm()
        if useNatural, NeuralTTS.isInstalled { neural.prewarm() }
    }

    /// Called when the user starts talking: reloads the voice in the background if it was freed while idle.
    func warmNatural() {
        if useNatural, NeuralTTS.isInstalled { neural.prewarm() }
    }

    func beginReply() {
        system.beginReply()
        neural.beginReply()
    }

    func enqueue(_ sentence: String) {
        if natural { neural.enqueue(sentence) } else { system.enqueue(sentence) }
    }

    func stop() {
        system.stop()
        neural.stop()
    }
}
