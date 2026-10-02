import Foundation

/// One content turn for the Gemini REST API.
struct GeminiTurn: Sendable {
    enum Role: String, Sendable { case user, model }
    var role: Role
    var text: String
    var jpeg: Data? = nil
    /// Extra inline parts (attached images, PDFs).
    var inline: [InlinePart] = []
}

struct InlinePart: Sendable, Equatable {
    var mimeType: String
    var data: Data
}

struct GeminiRequest: Sendable {
    var model: String
    var system: String
    var turns: [GeminiTurn]
    /// "off" omits thinkingConfig; otherwise sent as thinkingLevel.
    var thinkingLevel: String
    var maxOutputTokens: Int = 1024
    /// Give up if no text arrives within this many seconds (talk latency guard).
    var firstTokenTimeout: TimeInterval? = nil
}

enum GeminiError: LocalizedError, Equatable {
    case missingKey
    case http(Int, String)
    case badResponse
    case modelNotFound(String)
    /// The key's plan has no quota for this model at all (e.g. Pro on the free tier).
    case quotaUnavailable(String)
    /// A temporary free-tier limit; the server says when to retry.
    case rateLimited(String, retryAfter: Int?)
    /// No first token within the latency budget.
    case slow(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "add your gemini api key in settings first"
        case .http(429, _): "gemini is rate-limiting us, give it a moment"
        case .http(401, _), .http(403, _): "gemini didn't accept the api key"
        case .http(let code, _) where code >= 500: "gemini is having a moment, try again"
        case .http(let code, let msg): "gemini error \(code): \(msg.prefix(120))"
        case .badResponse: "got a weird reply from gemini"
        case .modelNotFound(let m): "model \"\(m)\" wasn't found, check the model id in settings"
        case .quotaUnavailable(let m): "your gemini plan doesn't include \(m) — enable billing or pick another model in settings"
        case .slow(let m): "\(m) is too slow right now — try again"
        case .rateLimited(let m, let s): "hit the free-tier limit for \(m)" + (s.map { " — try again in \($0)s" } ?? " — try again in a minute")
        }
    }
}

/// Minimal Gemini REST client with SSE streaming. No SDK.
actor GeminiClient {
    static let base = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!
    private let session: URLSession
    private let apiKey: @Sendable () -> String?
    /// Thinking level each model actually accepts (learned from 400s, so the bad level is tried once).
    private var thinkingOverride: [String: String] = [:]

    static let thinkingLadder = ["minimal", "low", "medium", "high"]

    /// The next level to try after `level` was rejected (nil = send no thinking config).
    nonisolated static func nextThinking(after level: String) -> String? {
        guard let i = thinkingLadder.firstIndex(of: level), i + 1 < thinkingLadder.count else { return nil }
        return thinkingLadder[i + 1]
    }

    func effectiveThinking(model: String, requested: String) -> String {
        thinkingOverride[model] ?? requested
    }

    func learnThinking(model: String, level: String) { thinkingOverride[model] = level }

    /// Classifies an error body: is this "no quota at all on this plan" (don't retry, fall back)?
    /// "Please retry in 48.27s." → 49
    nonisolated static func retryAfter(_ msg: String) -> Int? {
        guard let r = msg.range(of: #"retry in ([0-9.]+)s"#, options: .regularExpression) else { return nil }
        let num = msg[r].replacingOccurrences(of: "retry in ", with: "").replacingOccurrences(of: "s", with: "")
        return Double(num).map { Int($0.rounded(.up)) }
    }

    nonisolated static func isPlanQuota(_ msg: String) -> Bool {
        // Only a hard zero means "not on this plan"; other free-tier 429s are temporary limits.
        msg.lowercased().contains("limit: 0")
    }

    init(apiKey: @escaping @Sendable () -> String?) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
        self.apiKey = apiKey
    }

    /// Opens a TLS connection early so the real request skips the handshake.
    func preconnect() async {
        guard let key = apiKey() else { return }
        var req = URLRequest(url: Self.base.appendingPathComponent("models"))
        req.httpMethod = "HEAD"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        _ = try? await session.data(for: req)
    }

    /// Validates a key (and that the model exists) without generating tokens.
    func validate(key: String, model: String) async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent("models/\(model)"))
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw GeminiError.modelNotFound(model) }
        guard code == 200 else { throw GeminiError.http(code, Self.message(from: data)) }
    }

    /// Non-streaming `generateContent` with a raw JSON body (agents / function calling).
    /// Raw in, raw out, so model parts (incl. thought signatures) round-trip unchanged.
    func generateRaw(model: String, body: Data, timeout: TimeInterval = 60) async throws -> Data {
        guard let key = apiKey(), !key.isEmpty else { throw GeminiError.missingKey }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: Self.base.appendingPathComponent("models/\(model):generateContent"))
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = body
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            if code == 404 { throw GeminiError.modelNotFound(model) }
            let msg = Self.message(from: data)
            if code == 429, Self.isPlanQuota(msg) { throw GeminiError.quotaUnavailable(model) }
            if code == 429, let wait = Self.retryAfter(msg), wait > 3 { throw GeminiError.rateLimited(model, retryAfter: wait) }
            if (code == 429 || code >= 500), attempt < 2 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * (1 << attempt)))
                continue
            }
            throw GeminiError.http(code, Self.message(from: data))
        }
    }

    /// Runs a request to completion and returns the whole text (for background jobs).
    nonisolated func complete(_ request: GeminiRequest) async throws -> (text: String, usage: TokenUsage?) {
        var out = ""
        var usage: TokenUsage?
        for try await c in stream(request) {
            out += c.text
            if let u = c.usage { usage = u }
        }
        return (out, usage)
    }

    nonisolated func stream(_ request: GeminiRequest) -> AsyncThrowingStream<GeminiChunk, Error> {
        AsyncThrowingStream { continuation in
            let gotText = OnceFlag()
            let task = Task {
                do {
                    try await self.run(request, into: continuation, onText: { _ = gotText.claim() })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Latency guard: no text in time → cancel and report "slow" so the caller can fall back.
            let watchdog: Task<Void, Never>? = request.firstTokenTimeout.map { limit in
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    if !Task.isCancelled, gotText.claim() {
                        task.cancel()
                        continuation.finish(throwing: GeminiError.slow(request.model))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel(); watchdog?.cancel() }
        }
    }

    private func run(_ request: GeminiRequest, into cont: AsyncThrowingStream<GeminiChunk, Error>.Continuation,
                     onText: @Sendable () -> Void = {}) async throws {
        guard let key = apiKey(), !key.isEmpty else { throw GeminiError.missingKey }
        var req = request
        if req.thinkingLevel != "off" { req.thinkingLevel = effectiveThinking(model: req.model, requested: req.thinkingLevel) }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let includeThinking = req.thinkingLevel != "off"
            let urlReq = try Self.makeURLRequest(req, key: key, includeThinking: includeThinking)
            let t0 = ProcessInfo.processInfo.systemUptime
            let (bytes, resp) = try await session.bytes(for: urlReq)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ttfb = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            Log.perf.notice("gemini headers \(ttfb)ms status=\(code) body=\(urlReq.httpBody?.count ?? 0)B model=\(req.model, privacy: .public) thinking=\(includeThinking ? req.thinkingLevel : "none", privacy: .public)")
            if code == 200 {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    if let chunk = SSEParser.parse(line: line) {
                        if !chunk.text.isEmpty { onText() }
                        cont.yield(chunk)
                    }
                }
                return
            }
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 8192 { break } }
            let msg = Self.message(from: body)
            if code == 400, includeThinking, msg.lowercased().contains("thinking level") {
                // Step to the next level this model accepts, and remember it.
                let next = Self.nextThinking(after: req.thinkingLevel) ?? "off"
                Log.perf.notice("thinking level \(req.thinkingLevel, privacy: .public) rejected by \(req.model, privacy: .public); trying \(next, privacy: .public)")
                req.thinkingLevel = next
                learnThinking(model: req.model, level: next)
                continue
            }
            if code == 404 { throw GeminiError.modelNotFound(req.model) }
            if code == 429, Self.isPlanQuota(msg) { throw GeminiError.quotaUnavailable(req.model) }
            // Free-tier limit with a long wait: tell the user instead of hammering the API.
            if code == 429, let wait = Self.retryAfter(msg), wait > 3 { throw GeminiError.rateLimited(req.model, retryAfter: wait) }
            if (code == 429 || code >= 500), attempt < 2 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(400_000_000 * (1 << attempt)))
                continue
            }
            throw GeminiError.http(code, msg)
        }
    }

    static func makeURLRequest(_ r: GeminiRequest, key: String, includeThinking: Bool) throws -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent("models/\(r.model):streamGenerateContent"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(r, includeThinking: includeThinking))
        return req
    }

    static func body(_ r: GeminiRequest, includeThinking: Bool) -> [String: Any] {
        let contents: [[String: Any]] = r.turns.map { t in
            var parts: [[String: Any]] = []
            if let jpeg = t.jpeg {
                parts.append(["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]])
            }
            for p in t.inline {
                parts.append(["inlineData": ["mimeType": p.mimeType, "data": p.data.base64EncodedString()]])
            }
            parts.append(["text": t.text])
            return ["role": t.role.rawValue, "parts": parts]
        }
        var gen: [String: Any] = ["maxOutputTokens": r.maxOutputTokens]
        if includeThinking { gen["thinkingConfig"] = ["thinkingLevel": r.thinkingLevel] }
        return [
            "systemInstruction": ["parts": [["text": r.system]]],
            "contents": contents,
            "generationConfig": gen,
        ]
    }

    static func message(from data: Data) -> String {
        struct E: Decodable { struct Inner: Decodable { var message: String? }; var error: Inner? }
        if let e = try? JSONDecoder().decode(E.self, from: data), let m = e.error?.message { return m }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}
