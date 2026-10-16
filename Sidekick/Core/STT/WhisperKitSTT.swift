import Foundation
import WhisperKit

/// Loads WhisperKit once, warms it, keeps it resident.
actor WhisperKitSTT: STTProvider {
    enum LoadState: Equatable { case idle, downloading(Double), loading, ready, failed(String) }

    private var kit: WhisperKit?
    private var loadedModel: WhisperModel?

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sidekick/Models", isDirectory: true)
    }

    var isReady: Bool { kit != nil }
    private(set) var isLoading = false

    /// A complete, previously downloaded model folder (all three Core ML parts present), if any.
    nonisolated static func localModel(_ model: WhisperModel, base: URL = modelsDirectory) -> URL? {
        let dir = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)", isDirectory: true)
        let parts = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        let ok = parts.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        return ok ? dir : nil
    }

    /// Downloads (if needed), loads and warms the model. Progress is reported on the main actor.
    func load(_ model: WhisperModel, progress: @escaping @Sendable (LoadState) -> Void) async {
        if loadedModel == model, kit != nil { progress(.ready); return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        kit = nil
        loadedModel = nil
        do {
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            // Use the copy already on disk — no network needed (launching at login before Wi-Fi is up used to
            // fail here and leave Sidekick "warming up" forever).
            let folder: URL
            if let local = Self.localModel(model) {
                folder = local
            } else {
                progress(.downloading(0))
                folder = try await WhisperKit.download(
                    variant: model.rawValue,
                    downloadBase: Self.modelsDirectory,
                    progressCallback: { p in progress(.downloading(p.fractionCompleted)) }
                )
            }
            progress(.loading)
            let config = WhisperKitConfig(
                model: model.rawValue,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let k = try await WhisperKit(config)
            kit = k
            // Warm-up: 1 s of low noise through the same decode path real requests use
            // (incl. language detection), so the first real request is fast.
            var rng = SystemRandomNumberGenerator()
            let noise = (0..<16_000).map { _ in Float.random(in: -0.002...0.002, using: &rng) }
            _ = try? await transcribe(noise, language: nil, prompt: nil)
            _ = try? await transcribe(noise, language: "en", prompt: nil)
            loadedModel = model
            progress(.ready)
            Log.stt.info("whisper ready: \(model.rawValue, privacy: .public)")
        } catch {
            Log.stt.error("whisper load failed: \(error.localizedDescription, privacy: .public)")
            progress(.failed(error.localizedDescription))
        }
    }

    func transcribe(_ samples: [Float], language: String?, prompt: String?) async throws -> String {
        guard let kit else { throw STTError.notReady }
        var options = DecodingOptions(
            language: language,
            temperatureFallbackCount: 2,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        if let prompt, !prompt.isEmpty, let tok = kit.tokenizer {
            let begin = tok.specialTokens.specialTokenBegin
            options.promptTokens = tok.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces)).filter { $0 < begin }
            options.usePrefillPrompt = true
        }
        let results = try await kit.transcribe(audioArray: samples, audioArrayOffset: 0, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum STTError: LocalizedError {
        case notReady
        var errorDescription: String? { "still warming up the ears, try again in a sec" }
    }
}
