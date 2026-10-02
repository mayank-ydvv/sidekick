import Foundation

@MainActor
protocol TTSProvider: AnyObject {
    var isSpeaking: Bool { get }
    /// Fired once when the first utterance of a session starts speaking.
    var onFirstAudio: (() -> Void)? { get set }
    /// Fired when the queue drains.
    var onFinished: (() -> Void)? { get set }
    func enqueue(_ sentence: String)
    func stop()
}
