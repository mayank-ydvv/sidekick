import Foundation
import Observation

enum DictationState: Equatable { case idle, holding, handsFree, processing }

enum TalkPhase: Equatable {
    case idle, listening, transcribing, thinking, speaking
    case message(String)   // friendly info/error line
}

/// Single source of truth for UI.
@MainActor
@Observable
final class AppState {
    var phase: TalkPhase = .idle
    var level: Float = 0
    var transcript = ""
    var reply = ""
    var bubbleVisible = false
    var dictation: DictationState = .idle
    var alwaysOn = false
    var dictationLevel: Float = 0
    /// Which model answered, when it isn't the normal one (e.g. "lite model · fast model busy ~40s").
    var modelNote: String?
    /// "step 2 of 5" while a lesson is running.
    var stepLabel: String?

    var whisper: WhisperKitSTT.LoadState = .idle
    var hasAPIKey = false
    var hotkeyInstalled = false

    /// Last measured latencies in ms, for Settings → About.
    var timings: [String: Int] = [:]

    var isBusy: Bool {
        switch phase {
        case .idle, .message: false
        default: true
        }
    }
}
