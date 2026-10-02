import Foundation

protocol STTProvider: Sendable {
    /// Transcribe 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float], language: String?, prompt: String?) async throws -> String
}

enum WhisperModel: String, CaseIterable, Codable, Identifiable {
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3-v20240930_turbo_632MB"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .base: "base (fastest)"
        case .small: "small (balanced)"
        case .largeTurbo: "large-v3-turbo (most accurate)"
        }
    }
}
