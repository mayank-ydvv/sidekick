import AppKit
import SwiftUI
import Observation

/// Runs one agent task: 5 s cancel window → Gemini function-calling loop (smart model, max 25 steps).
@MainActor
@Observable
final class AgentRunner {
    enum Status: Equatable {
        case idle
        case countdown(Int)
        case running
        case needsApproval(String)
        case asking(String)
        case done(String)
        case failed(String)
        case cancelled
    }

    struct Step: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var state: State
        enum State: Equatable { case running, done, failed, declined }
    }

    static let maxSteps = 25
    static let countdownSeconds = 5

    static let stepTimeout: TimeInterval = 90
    static let toolTimeout: TimeInterval = 60

    private(set) var status: Status = .idle
    private(set) var task = ""
    private(set) var steps: [Step] = []
    private(set) var files: [URL] = []
    var stepsExpanded = true

    /// Called when the run ends (summary to speak / show, files, the buddy it ran as).
    var onFinished: ((String, [URL], BuddyRecord?) -> Void)?
    /// Extra tools (buddies, notes, MCP servers), evaluated at the start of each run.
    var extraTools: () -> [AgentTool] = { [] }
    /// Routines run without a card: anything that needs approval is declined automatically.
    private(set) var headless = false
    /// Only read tools (proactive suggestions must never change anything).
    private(set) var readOnly = false
    nonisolated static let readOnlyTools: Set<String> = [
        "web_search", "fetch_url", "files_list", "files_read", "notes_search", "calendar_list_events",
        "reminders_list", "buddy_list", "wiki_search", "ui_read",
    ]
    private(set) var buddy: BuddyRecord?
    var buddyMemory: (BuddyRecord) -> String = { _ in "" }
    var onShow: (() -> Void)?
    /// Runs in the background with no task card (it only appears when the run needs the user),
    /// so the safety countdown is skipped — Esc still cancels.
    var quietRuns = true

    private let gemini: GeminiClient
    private let settings: AppSettings
    private let usage: UsageStore
    private let memory: MemoryStore
    private let db: AppDatabase
    private var work: Task<Void, Never>?
    private var decision: CheckedContinuation<Bool, Never>?
    private var answer: CheckedContinuation<String?, Never>?
    private var runRecord: AgentRunRecord?
    /// Computer use is allowed per task, asked once on the first ui_* action.
    private var computerUseAllowed = false
    private var tools: [AgentTool] = []

    init(gemini: GeminiClient, settings: AppSettings, usage: UsageStore, memory: MemoryStore, db: AppDatabase) {
        self.gemini = gemini
        self.settings = settings
        self.usage = usage
        self.memory = memory
        self.db = db
    }

    var isActive: Bool {
        switch status {
        case .countdown, .running, .needsApproval, .asking: true
        default: false
        }
    }

    var outputFolder: URL {
        if let buddy { return URL(fileURLWithPath: buddy.folderPath, isDirectory: true) }
        return BuddyStore.folder(for: "General Helper")
    }

    // MARK: Control

    @discardableResult
    func start(task: String, context: String = "", buddy: BuddyRecord? = nil, headless: Bool = false, readOnly: Bool = false) -> Bool {
        guard !isActive else { return false }
        self.readOnly = readOnly
        self.task = task
        self.buddy = buddy
        self.headless = headless
        steps = []
        files = []
        computerUseAllowed = false
        status = .countdown(Self.countdownSeconds)
        if !headless, !quietRuns { onShow?() }
        work = Task { [weak self] in
            guard let self else { return }
            for s in stride(from: headless || quietRuns ? 0 : Self.countdownSeconds, to: 0, by: -1) {
                self.status = .countdown(s)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            await self.loop(context: context)
        }
        return true
    }

    func cancel() {
        work?.cancel()
        work = nil
        decision?.resume(returning: false); decision = nil
        answer?.resume(returning: nil); answer = nil
        if isActive { status = .cancelled }
        persist(status: "cancelled")
    }

    func approve(_ yes: Bool) {
        decision?.resume(returning: yes)
        decision = nil
    }

    func reply(_ text: String) {
        answer?.resume(returning: text)
        answer = nil
    }

    /// A spoken reply while the agent waits. Returns true if consumed.
    func handleVoice(_ transcript: String) -> Bool {
        switch status {
        case .needsApproval:
            guard let yes = YesNo.answer(transcript) else { return false }
            approve(yes); return true
        case .asking:
            reply(transcript); return true
        case .countdown:
            let t = transcript.lowercased()
            if t.contains("cancel") || t.contains("stop") || t.contains("ruk") { cancel(); return true }
            return false
        default:
            return false
        }
    }

    // MARK: Loop

    private func loop(context: String) async {
        status = .running
        tools = ToolRegistry.all() + extraTools()
        if readOnly {
            let probe = ToolContext(outputFolder: outputFolder, allowedFolders: [], gemini: gemini, searchModel: "")
            tools = tools.filter { t in
                Self.readOnlyTools.contains(t.name) || (t.name.hasPrefix("mcp_") && !t.requiresConfirmation([:], probe))
            }
        }
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let task = task
        runRecord = try? await db.writer.write { db -> AgentRunRecord in
            var r = AgentRunRecord(task: task, status: "running")
            try r.insert(db)
            return r
        }

        let ctx = ToolContext(outputFolder: outputFolder,
                              allowedFolders: settings.data.agentFolders.map { URL(fileURLWithPath: $0) },
                              gemini: gemini, searchModel: settings.data.fastModel, fallbackModel: settings.data.cheapModel,
                              preferredBrowser: LocalTools.browserMentioned(in: task))
        let df = DateFormatter(); df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let system = Self.loadPrompt()
            .replacingOccurrences(of: "{DATE}", with: df.string(from: Date()))
            .replacingOccurrences(of: "{FOLDER}", with: outputFolder.path)
            .replacingOccurrences(of: "{PROFILE}", with: memory.promptProfile.isEmpty ? "(none)" : memory.promptProfile)
            + (buddy.map { "\nYou are the buddy \"\($0.name)\". Role: \($0.rolePrompt)\nYour notes so far:\n\(String(buddyMemory($0).suffix(1500)))" } ?? "")
            + (headless ? "\nThis is a scheduled routine: the user isn't watching. Don't ask questions; make reasonable assumptions." : "")
        var contents: [[String: Any]] = [[
            "role": "user",
            "parts": [["text": "Task: \(task)" + (context.isEmpty ? "" : "\n\nRecent conversation:\n\(context)")]],
        ]]
        var declarations = ToolRegistry.declarations(tools)
        if var fns = declarations[0]["functionDeclarations"] as? [[String: Any]] {
            fns.append(["name": "ask_user", "description": "Ask the user one short question when essential info is missing.",
                        "parameters": ["type": "object", "properties": ["question": ["type": "string"]], "required": ["question"]]])
            declarations[0]["functionDeclarations"] = fns
        }
        // Skip models that recently failed (used-up quota, not on the plan) instead of re-trying them every task.
        var model = settings.data.smartModel
        for candidate in [settings.data.smartModel, settings.data.fastModel] {
            guard ModelHealth.isBlocked(candidate) else { break }
            model = candidate == settings.data.smartModel ? settings.data.fastModel : settings.data.cheapModel
        }
        var thinking = await gemini.effectiveThinking(model: model, requested: model == settings.data.smartModel ? settings.data.smartThinkingLevel
                                                      : model == settings.data.cheapModel ? "minimal" : "low")

        for _ in 0..<Self.maxSteps {
            if Task.isCancelled { return }
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": contents,
                "tools": declarations,
            ]
            if thinking != "off" { body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": thinking]] }
            let data: Data
            do {
                let bodyData = try JSONSerialization.data(withJSONObject: body)
                let stepModel = model
                data = try await withTimeout(Self.stepTimeout) { [gemini] in
                    try await gemini.generateRaw(model: stepModel, body: bodyData, timeout: Self.stepTimeout)
                }
            } catch GeminiError.http(400, let msg) where thinking != "off" && msg.lowercased().contains("thinking level") {
                thinking = GeminiClient.nextThinking(after: thinking) ?? "off"
                await gemini.learnThinking(model: model, level: thinking)
                continue
            } catch GeminiError.rateLimited(_, let wait?) where model == settings.data.cheapModel && wait <= 65 {
                // Lowest model is briefly rate-limited: wait it out instead of failing the task.
                let i = addStep("free-tier limit — waiting \(wait)s")
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                if Task.isCancelled { return }
                setStep(i, .done)
                continue
            } catch let e as GeminiError where model != settings.data.cheapModel && TalkCoordinator.shouldFallBack(e) {
                // Smart model not on this plan / fast model rate-limited: step down a model and keep going.
                let next = model == settings.data.smartModel ? settings.data.fastModel : settings.data.cheapModel
                ModelHealth.block(model, for: e)
                _ = addStep("\(model) unavailable (\(e.localizedDescription.prefix(40))) — using \(next)")
                setStep(steps.count - 1, .done)
                model = next
                thinking = await gemini.effectiveThinking(model: model, requested: model == settings.data.cheapModel ? "minimal" : "low")
                continue
            } catch {
                if Task.isCancelled { return }
                return finish(.failed(error.localizedDescription))
            }
            let parsed = Self.parse(data)
            if let u = parsed.usage { usage.record(model: model, usage: u) }
            guard let content = parsed.content else { return finish(.failed("got an empty reply from the model")) }
            contents.append(content)   // echo the model turn verbatim (keeps thought signatures)

            if parsed.calls.isEmpty {
                let summary = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return finish(.done(summary.isEmpty ? "done." : summary))
            }

            var responses: [[String: Any]] = []
            var images: [[String: Any]] = []
            for call in parsed.calls {
                if Task.isCancelled { return }
                let result = await execute(call, ctx: ctx)
                responses.append(["functionResponse": ["name": call.name, "response": ["result": result.text]]])
                if let img = result.image {
                    images.append(["inlineData": ["mimeType": "image/jpeg", "data": img.base64EncodedString()]])
                }
            }
            // Only the newest screenshot is kept in context (older ones are dropped to save tokens).
            if !images.isEmpty { Self.dropOldImages(&contents) }
            contents.append(["role": "user", "parts": responses + images.suffix(1)])
        }
        finish(.failed("stopped after \(Self.maxSteps) steps"))
    }

    private func execute(_ call: FunctionCall, ctx: ToolContext) async -> ToolResult {
        if call.name == "ask_user", headless {
            _ = addStep("skipped a question (routine)")
            return ToolResult(text: "the user isn't available; make a reasonable assumption")
        }
        if call.name == "ask_user" {
            let q = call.args["question"] as? String ?? "can you tell me more?"
            let i = addStep("asked: \(q)")
            status = .asking(q)
            let a: String? = await withCheckedContinuation { answer = $0 }
            status = .running
            setStep(i, a == nil ? .declined : .done)
            return ToolResult(text: a ?? "the user didn't answer; make a reasonable assumption")
        }
        guard let tool = ToolRegistry.named(call.name, in: tools) else {
            return .error("unknown tool \(call.name)")
        }
        let summary = tool.summary(call.args)
        let i = addStep(summary)
        if headless, ComputerUse.isComputerUse(call.name) || tool.requiresConfirmation(call.args, ctx) {
            setStep(i, .declined)
            return .error("this needs the user's approval, which isn't possible in a scheduled routine; skip it and mention it in your summary")
        }
        let auto = settings.data.autoApprove
        if auto, ComputerUse.isComputerUse(call.name) { computerUseAllowed = true }
        if ComputerUse.isComputerUse(call.name), !computerUseAllowed {
            status = .needsApproval("allow sidekick to use your mac for this task?")
            let ok: Bool = await withCheckedContinuation { decision = $0 }
            status = .running
            guard ok else { setStep(i, .declined); return .error("the user didn't allow computer use; explain what they can do instead") }
            computerUseAllowed = true
        }
        if tool.requiresConfirmation(call.args, ctx), !(auto && !Self.isRisky(call)) {
            status = .needsApproval(summary)
            let ok: Bool = await withCheckedContinuation { decision = $0 }
            status = .running
            guard ok else { setStep(i, .declined); return .error("the user declined this action") }
        }
        do {
            let args = call.args
            let r = try await withTimeout(Self.toolTimeout) { try await tool.run(args, ctx) }
            setStep(i, r.isError ? .failed : .done)
            files += r.files.filter { !files.contains($0) }
            return r
        } catch {
            setStep(i, .failed)
            return .error(error.localizedDescription)
        }
    }

    /// Even with auto-approve, shell commands that can destroy data or change the system still ask first.
    nonisolated static func isRisky(_ call: FunctionCall) -> Bool { isRisky(tool: call.name, command: call.args["command"] as? String) }

    nonisolated static func isRisky(tool: String, command: String?) -> Bool {
        guard tool == "run_shell", let cmd = command?.lowercased() else { return false }
        let words = cmd.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init)
        let risky: Set<String> = ["rm", "rmdir", "sudo", "mkfs", "dd", "shutdown", "reboot", "halt", "kill", "killall", "pkill",
                                  "chmod", "chown", "launchctl", "csrutil", "spctl", "defaults", "security", "srm", "truncate", "mv"]
        if words.contains(where: risky.contains) { return true }
        return cmd.contains("diskutil erase") || cmd.contains(">") || cmd.contains("| sh") || cmd.contains("| bash") || cmd.contains("trash")
    }

    private func addStep(_ t: String) -> Int {
        withAnimation(Motion.snappy) { steps.append(Step(title: t, state: .running)) }
        return steps.count - 1
    }

    private func setStep(_ i: Int, _ s: Step.State) {
        guard steps.indices.contains(i) else { return }
        withAnimation(Motion.bouncy) { steps[i].state = s }
    }

    private func finish(_ s: Status) {
        status = s
        work = nil
        switch s {
        case .done(let summary):
            persist(status: "done")
            onFinished?(summary, files, buddy)
        case .failed(let m):
            persist(status: "failed")
            onFinished?("i couldn't finish that: \(m)", files, buddy)
        default:
            break
        }
    }

    private func persist(status: String) {
        guard var rec = runRecord else { return }
        rec.status = status
        rec.endedAt = Date()
        rec.steps = (try? String(data: JSONSerialization.data(withJSONObject: steps.map { ["title": $0.title, "state": "\($0.state)"] }), encoding: .utf8)) ?? "[]"
        rec.filesJSON = (try? String(data: JSONSerialization.data(withJSONObject: files.map(\.path)), encoding: .utf8)) ?? "[]"
        runRecord = nil
        Task { [db, rec] in _ = try? await db.writer.write { db in try rec.update(db) } }
    }

    /// Removes inlineData parts from earlier user turns.
    nonisolated static func dropOldImages(_ contents: inout [[String: Any]]) {
        for i in contents.indices where contents[i]["role"] as? String == "user" {
            if let parts = contents[i]["parts"] as? [[String: Any]] {
                contents[i]["parts"] = parts.filter { $0["inlineData"] == nil }
            }
        }
    }

    // MARK: Parsing

    struct FunctionCall { var name: String; var args: [String: Any] }

    struct Parsed {
        var content: [String: Any]?
        var calls: [FunctionCall] = []
        var text = ""
        var usage: TokenUsage?
    }

    nonisolated static func parse(_ data: Data) -> Parsed {
        var p = Parsed()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return p }
        if let u = json["usageMetadata"] as? [String: Any] {
            p.usage = TokenUsage(inputTokens: u["promptTokenCount"] as? Int ?? 0,
                                 outputTokens: (u["candidatesTokenCount"] as? Int ?? 0) + (u["thoughtsTokenCount"] as? Int ?? 0))
        }
        guard let cand = (json["candidates"] as? [[String: Any]])?.first,
              var content = cand["content"] as? [String: Any] else { return p }
        if content["role"] == nil { content["role"] = "model" }
        p.content = content
        for part in content["parts"] as? [[String: Any]] ?? [] {
            if let fc = part["functionCall"] as? [String: Any], let name = fc["name"] as? String {
                p.calls.append(FunctionCall(name: name, args: fc["args"] as? [String: Any] ?? [:]))
            } else if let t = part["text"] as? String, part["thought"] as? Bool != true {
                p.text += t
            }
        }
        return p
    }

    private static func loadPrompt() -> String {
        Bundle.main.url(forResource: "agent", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "You are an agent. Use tools to finish the task, then summarize in one sentence."
    }
}

/// Runs an async operation with a deadline.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let r = try await group.next()!
        group.cancelAll()
        return r
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "that took too long" }
}
