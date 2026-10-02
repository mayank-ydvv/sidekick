import Foundation
import Observation

/// Owns MCP connections and exposes their tools to agents. Tools that aren't marked read-only ask first.
@MainActor
@Observable
final class MCPManager {
    enum Status: Equatable { case off, connecting, connected(Int), failed(String) }

    var servers: [MCPServerConfig] {
        didSet { save() }
    }
    private(set) var status: [UUID: Status] = [:]
    private var clients: [UUID: MCPClient] = [:]
    private(set) var agentTools: [AgentTool] = []

    init() {
        if let d = UserDefaults.standard.data(forKey: "mcp.servers"), let s = try? JSONDecoder().decode([MCPServerConfig].self, from: d) {
            servers = s
        } else {
            servers = []
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(d, forKey: "mcp.servers") }
    }

    static func envAccount(_ id: UUID) -> String { "mcp-env-\(id.uuidString)" }

    func env(for id: UUID) -> String { Keychain.get(Self.envAccount(id)) ?? "" }

    /// "KEY=value" lines, stored in the Keychain (tokens never touch UserDefaults).
    func setEnv(_ text: String, for id: UUID) { Keychain.set(text, for: Self.envAccount(id)) }

    nonisolated static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    func connectAll() {
        for s in servers where s.enabled { connect(s) }
    }

    func connect(_ s: MCPServerConfig) {
        status[s.id] = .connecting
        let client = MCPClient(config: s, env: Self.parseEnv(env(for: s.id)))
        Task {
            await clients[s.id]?.disconnect()
            clients[s.id] = client
            do {
                try await withTimeout(45) { try await client.connect() }
                let tools = await client.tools
                status[s.id] = .connected(tools.count)
            } catch {
                status[s.id] = .failed(error.localizedDescription)
                await client.disconnect()
                clients[s.id] = nil
            }
            await rebuildTools()
        }
    }

    func remove(_ s: MCPServerConfig) {
        Task { await clients[s.id]?.disconnect() }
        clients[s.id] = nil
        status[s.id] = nil
        Keychain.delete(Self.envAccount(s.id))
        servers.removeAll { $0.id == s.id }
        Task { await rebuildTools() }
    }

    func disconnectAll() {
        for c in clients.values { Task { await c.disconnect() } }
    }

    private func rebuildTools() async {
        var out: [AgentTool] = []
        for s in servers {
            guard let client = clients[s.id] else { continue }
            for t in await client.tools {
                let schema = (try? JSONSerialization.jsonObject(with: t.inputSchemaJSON) as? [String: Any]) ?? [:]
                let sendable = schema.mapValues { $0 as! (any Sendable) }
                let toolName = t.name
                out.append(AgentTool(
                    name: MCPClient.toolName(server: s.name, tool: t.name),
                    description: "[\(s.name)] " + String(t.description.prefix(400)),
                    parameters: sendable,
                    requiresConfirmation: { _, _ in !t.readOnly },
                    run: { args, _ in
                        let r = try await client.call(tool: toolName, arguments: args)
                        return ToolResult(text: r.text, isError: r.isError)
                    }))
            }
        }
        agentTools = out
    }
}
