import Foundation

/// One parsed streaming chunk from Gemini.
struct GeminiChunk: Equatable, Sendable {
    var text: String
    var usage: TokenUsage?
    var finishReason: String?
}

struct TokenUsage: Equatable, Sendable, Codable {
    var inputTokens: Int
    var outputTokens: Int
}

/// Parses Server-Sent-Event lines into Gemini chunks. Malformed payloads are ignored.
enum SSEParser {
    /// Returns nil for non-data lines, keep-alives, or malformed JSON.
    static func parse(line: String) -> GeminiChunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        guard let resp = try? JSONDecoder().decode(GenerateContentResponse.self, from: data) else { return nil }
        return chunk(from: resp)
    }

    static func chunk(from resp: GenerateContentResponse) -> GeminiChunk {
        let cand = resp.candidates?.first
        let text = cand?.content?.parts?
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined() ?? ""
        var usage: TokenUsage?
        if let u = resp.usageMetadata {
            usage = TokenUsage(
                inputTokens: u.promptTokenCount ?? 0,
                outputTokens: (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0)
            )
        }
        return GeminiChunk(text: text, usage: usage, finishReason: cand?.finishReason)
    }
}

struct GenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { var text: String?; var thought: Bool? }
            var parts: [Part]?
        }
        var content: Content?
        var finishReason: String?
    }
    struct Usage: Decodable {
        var promptTokenCount: Int?
        var candidatesTokenCount: Int?
        var thoughtsTokenCount: Int?
    }
    var candidates: [Candidate]?
    var usageMetadata: Usage?
}
