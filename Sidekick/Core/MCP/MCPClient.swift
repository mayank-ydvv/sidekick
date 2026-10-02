import Foundation

/// A configured MCP server (Settings → Connections). Env values live in the Keychain.
struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case stdio, http }
    var id = UUID()
    var name: String
    var kind: Kind
    /// stdio: command line (e.g. "npx -y @modelcontextprotocol/server-github"); http: endpoint URL.
    var target: String
    var enabled = true
}

struct MCPTool: Equatable, Sendable {
    var name: String
    var description: String
    var inputSchemaJSON: Data
    var readOnly: Bool
}

enum MCPError: LocalizedError {
    case notConnected, badResponse, server(String), timeout
    var errorDescription: String? {
        switch self {
        case .notConnected: "not connected"
        case .badResponse: "the server sent something unexpected"
        case .server(let m): m
        case .timeout: "the server didn't answer in time"
        }
    }
}

/// Minimal MCP client: JSON-RPC 2.0 over stdio (newline-delimited) or Streamable HTTP (JSON or SSE replies).
actor MCPClient {
    let config: MCPServerConfig
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var sessionId: String?
    private let env: [String: String]
    private(set) var tools: [MCPTool] = []

    static let protocolVersion = "2025-06-18"

    init(config: MCPServerConfig, env: [String: String]) {
        self.config = config
        self.env = env
    }

    // MARK: Lifecycle

    func connect() async throws {
        if config.kind == .stdio { try launch() }
        _ = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Sidekick", "version": "0.8.0"],
        ])
        try await notify("notifications/initialized")
        let result = try await request("tools/list", params: [:])
        tools = Self.parseTools(result)
    }

    func disconnect() {
        process?.terminate()
        process = nil
        for (_, c) in pending { c.resume(throwing: MCPError.notConnected) }
        pending = [:]
    }

    func call(tool: String, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let r = try await request("tools/call", params: ["name": tool, "arguments": arguments], timeout: 120)
        return Self.parseCallResult(r)
    }

    // MARK: stdio

    private func launch() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", config.target]   // login shell so npx/uvx are on PATH
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { await self?.received(d) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(msg) }
        }
    }

    private func handle(_ msg: [String: Any]) {
        guard let id = (msg["id"] as? Int) ?? (msg["id"] as? NSNumber)?.intValue, let c = pending.removeValue(forKey: id) else { return }
        if let err = msg["error"] as? [String: Any] {
            c.resume(throwing: MCPError.server(err["message"] as? String ?? "error"))
        } else {
            c.resume(returning: msg["result"] as? [String: Any] ?? [:])
        }
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if config.kind == .http { return try await post(msg, expectId: id) }
        guard let stdin else { throw MCPError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: msg) + Data([0x0A])
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            stdin.write(data)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: MCPError.timeout)
    }

    private func notify(_ method: String) async throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if config.kind == .http { _ = try? await post(msg, expectId: nil); return }
        stdin?.write(try JSONSerialization.data(withJSONObject: msg) + Data([0x0A]))
    }

    private func post(_ msg: [String: Any], expectId: Int?) async throws -> [String: Any] {
        guard let url = URL(string: config.target) else { throw MCPError.notConnected }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionId { req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if let token = env["AUTHORIZATION"] ?? env["TOKEN"] {
            req.setValue(token.hasPrefix("Bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        if let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = sid }
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            throw MCPError.server("http \(http?.statusCode ?? 0)")
        }
        guard expectId != nil else { return [:] }
        let isSSE = http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") ?? false
        guard let reply = isSSE ? Self.lastSSEMessage(data) : (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) else {
            throw MCPError.badResponse
        }
        if let err = reply["error"] as? [String: Any] { throw MCPError.server(err["message"] as? String ?? "error") }
        return reply["result"] as? [String: Any] ?? [:]
    }

    // MARK: Pure parsing (tested)

    static func lastSSEMessage(_ data: Data) -> [String: Any]? {
        var last: [String: Any]?
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], obj["id"] != nil { last = obj }
        }
        return last
    }

    static func parseTools(_ result: [String: Any]) -> [MCPTool] {
        (result["tools"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let schema = (t["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
            let ann = t["annotations"] as? [String: Any]
            return MCPTool(name: name, description: t["description"] as? String ?? "",
                           inputSchemaJSON: (try? JSONSerialization.data(withJSONObject: sanitize(schema))) ?? Data("{}".utf8),
                           readOnly: ann?["readOnlyHint"] as? Bool ?? false)
        }
    }

    static func parseCallResult(_ r: [String: Any]) -> (text: String, isError: Bool) {
        let content = r["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { c -> String? in
            if let t = c["text"] as? String { return t }
            if let res = c["resource"] as? [String: Any] { return res["text"] as? String ?? res["uri"] as? String }
            return nil
        }.joined(separator: "\n")
        return (text.isEmpty ? "(no output)" : String(text.prefix(30_000)), r["isError"] as? Bool ?? false)
    }

    /// Gemini accepts an OpenAPI subset: drop keys it rejects ($schema, additionalProperties, …).
    static func sanitize(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in d where !["$schema", "additionalProperties", "$ref", "$defs", "definitions", "default", "examples", "const", "oneOf", "allOf", "anyOf", "patternProperties"].contains(k) {
                out[k] = sanitize(val)
            }
            return out
        }
        if let a = v as? [Any] { return a.map(sanitize) }
        return v
    }

    /// "mcp_github_create_issue" style names Gemini accepts (letters, digits, _ ; max 64).
    static func toolName(server: String, tool: String) -> String {
        let raw = "mcp_\(server)_\(tool)".lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(String(raw).prefix(64))
    }
}
