import Foundation

/// What a tool returns to the model (and which files it produced, for the agent card).
struct ToolResult: Sendable {
    var text: String
    var files: [URL] = []
    var isError = false
    /// Optional screenshot for the model (computer use).
    var image: Data? = nil

    static func error(_ s: String) -> ToolResult { ToolResult(text: "error: " + s, isError: true) }
}

/// Context passed to every tool call.
struct ToolContext: Sendable {
    /// Where outputs are written (the buddy's folder).
    var outputFolder: URL
    /// Folders the user approved for reading/writing, in addition to `outputFolder`.
    var allowedFolders: [URL]
    var gemini: GeminiClient
    var searchModel: String
    /// Used when `searchModel` is rate-limited or overloaded.
    var fallbackModel: String? = nil
    /// A browser the user named in the task ("…on chrome"): web links open there even if the model forgets to say so.
    var preferredBrowser: String? = nil
    /// The user's own request (used e.g. to keep capitals they actually asked for).
    var task: String = ""
}

/// One callable tool: name + JSON schema (OpenAPI subset Gemini understands) + implementation.
struct AgentTool: Sendable {
    let name: String
    let description: String
    /// JSON object schema for parameters.
    let parameters: [String: any Sendable]
    /// Always ask the user before running (shell, overwrite, anything destructive or outward-facing).
    let requiresConfirmation: @Sendable ([String: Any], ToolContext) -> Bool
    let run: @Sendable ([String: Any], ToolContext) async throws -> ToolResult

    var declaration: [String: Any] {
        ["name": name, "description": description, "parameters": parameters]
    }

    /// Human-readable one-liner for the agent card and confirmations.
    func summary(_ args: [String: Any]) -> String {
        // Typed text is shown too (so a wrong "H" is visible), unless it looks like a secret.
        if name == "ui_type", let t = args["text"] as? String {
            return ComputerUse.looksSensitive(t) ? "ui_type: ••••" : "ui_type: \"\(t.prefix(60))\""
        }
        let keys = ["command", "path", "url", "query", "app", "title", "name", "filename"]
        for k in keys { if let v = args[k] as? String { return "\(name): \(v.prefix(80))" } }
        return name
    }
}

enum Schema {
    static func object(_ props: [String: [String: any Sendable]], required: [String] = []) -> [String: any Sendable] {
        ["type": "object", "properties": props, "required": required]
    }
    static func string(_ d: String) -> [String: any Sendable] { ["type": "string", "description": d] }
    static func integer(_ d: String) -> [String: any Sendable] { ["type": "integer", "description": d] }
    static func array(_ d: String, items: [String: any Sendable]) -> [String: any Sendable] {
        ["type": "array", "description": d, "items": items]
    }
}

enum ToolRegistry {
    static func all() -> [AgentTool] {
        LocalTools.all + FileTools.all + WebTools.all + AppleTools.all + [ShellTool.tool] + ComputerUse.all
    }

    static func named(_ n: String, in tools: [AgentTool]) -> AgentTool? { tools.first { $0.name == n } }

    static func declarations(_ tools: [AgentTool]) -> [[String: Any]] {
        [["functionDeclarations": tools.map(\.declaration)]]
    }
}
