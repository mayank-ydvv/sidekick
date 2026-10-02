import AVFoundation

/// Local, free TTS via AVSpeechSynthesizer with a sentence queue and instant stop.
@MainActor
final class SystemTTS: NSObject, TTSProvider {
    var onFirstAudio: (() -> Void)?
    var onFinished: (() -> Void)?

    var voiceIdentifier: String?
    /// Voice chosen for the current reply's language (reset by `stop()`).
    private var replyVoice: String?
    private lazy var voices = VoiceSelector.installed()
    /// 0…1, AVSpeechUtterance rate scale.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1.0
    var volume: Float = 1.0

    private let synth = AVSpeechSynthesizer()
    private var pending = Set<ObjectIdentifier>()
    private var startedThisSession = false

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { !pending.isEmpty }

    func enqueue(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        // Decide the voice once per reply (on its first sentence) so it never switches mid-answer.
        if replyVoice == nil { replyVoice = VoiceSelector.pick(for: text, preferred: voiceIdentifier, voices: voices) ?? "" }
        if let id = replyVoice, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else if let voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        u.rate = rate
        u.pitchMultiplier = pitch
        u.volume = volume
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        pending.insert(ObjectIdentifier(u))
        synth.speak(u)
    }

    /// Speaks a silent utterance so the audio pipeline and voice are loaded before the first reply.
    func prewarm() {
        let u = AVSpeechUtterance(string: " ")
        if let voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { u.voice = v }
        u.volume = 0
        synth.speak(u)
    }

    /// A new reply starts: pick its voice from its first sentence.
    func beginReply() { replyVoice = nil }

    func stop() {
        replyVoice = nil
        pending.removeAll()
        startedThisSession = false
        synth.stopSpeaking(at: .immediate)
    }

    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            return $0.name < $1.name
        }
    }

    fileprivate func didStart(_ id: ObjectIdentifier) {
        if pending.contains(id), !startedThisSession {
            startedThisSession = true
            onFirstAudio?()
        }
    }

    fileprivate func didEnd(_ id: ObjectIdentifier) {
        guard pending.remove(id) != nil else { return }
        if pending.isEmpty {
            startedThisSession = false
            onFinished?()
        }
    }
}

extension SystemTTS: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didStart(id) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didEnd(id) }
    }
}
