import AppKit
import GRDB
import Observation
import UniformTypeIdentifiers

/// A file the user attached to a chat message.
struct ChatAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var mimeType: String
    var data: Data
    var isImage: Bool { mimeType.hasPrefix("image/") }

    static let maxBytes = 15_000_000

    static func load(_ url: URL) -> ChatAttachment? {
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let mime = type.preferredMIMEType ?? "application/octet-stream"
        return ChatAttachment(name: url.lastPathComponent, mimeType: mime, data: data)
    }
}

/// The assistant message currently streaming — observed only by its own row,
/// so the rest of the chat list doesn't re-render per chunk.
@MainActor
@Observable
final class StreamingMessage {
    var md = IncrementalMarkdown()
    var text = ""
    func append(_ s: String) { text += s; md.append(s) }
}

/// Conversations + messages for the notch chat, backed by GRDB (FTS5 search).
@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [ConversationRecord] = []
    /// Latest message text per conversation (list previews).
    private(set) var previews: [Int64: String] = [:]
    private(set) var messages: [MessageRecord] = []
    var selectedId: Int64? { didSet { if oldValue != selectedId { loadMessages() } } }
    var searchText = "" { didSet { runSearch() } }
    private(set) var searchHits: Set<Int64>? = nil
    var showArchived = false
    var streaming: StreamingMessage?
    var drafts: [Int64: String] = [:]
    var newChatDraft = ""
    var errorText: String?
    /// "answered by the lite model (fast model hit its limit)" — shown under the reply.
    var modelNote: String?

    private let db: AppDatabase
    private let gemini: GeminiClient
    private let settings: AppSettings
    private let usage: UsageStore
    private let memory: MemoryStore
    private let memoryUpdater: MemoryUpdater
    private let skills = AppSkillsLoader()
    private let capturer: ScreenCapturer
    private var observation: AnyDatabaseCancellable?
    private var task: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let chatTemplate: String
    private var smartUnavailable = false

    var activeSkills: (String) -> String = { _ in "" }
    /// Messages typed into a buddy's chat run that buddy as an agent.
    var onBuddyTask: ((Int64, String) -> Void)?

    init(db: AppDatabase, gemini: GeminiClient, settings: AppSettings, usage: UsageStore, memory: MemoryStore,
         memoryUpdater: MemoryUpdater, capturer: ScreenCapturer) {
        self.db = db
        self.gemini = gemini
        self.settings = settings
        self.usage = usage
        self.memory = memory
        self.memoryUpdater = memoryUpdater
        self.capturer = capturer
        if let url = Bundle.main.url(forResource: "chat", withExtension: "md"), let s = try? String(contentsOf: url, encoding: .utf8) {
            chatTemplate = s
        } else {
            chatTemplate = "You are Sidekick, a helpful assistant. Use markdown."
        }
        observe()
    }

    private func observe() {
        let obs = ValueObservation.tracking { db -> ([ConversationRecord], [Int64: String]) in
            let list = try ConversationRecord.order(Column("updatedAt").desc).fetchAll(db)
            var previews: [Int64: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT conversationId, text FROM message
                WHERE id IN (SELECT max(id) FROM message GROUP BY conversationId)
                """)
            for r in rows { previews[r["conversationId"]] = String((r["text"] as String? ?? "").prefix(140)) }
            return (list, previews)
        }
        observation = obs.start(in: db.writer, scheduling: .immediate, onError: { error in
            Log.app.error("conversation observation: \(error.localizedDescription, privacy: .public)")
        }, onChange: { [weak self] value in
            self?.conversations = value.0
            self?.previews = value.1
        })
    }

    // MARK: Lists

    var visibleConversations: [ConversationRecord] {
        conversations.filter { c in
            c.kind != "buddy" &&
            (showArchived || !c.archived || searchHits != nil)
                && (searchHits.map { hits in c.id.map(hits.contains) ?? false || c.title.localizedCaseInsensitiveContains(searchText) } ?? true)
        }
    }

    var grouped: [(ChatSection, [ConversationRecord])] {
        let now = Date()
        var buckets: [ChatSection: [ConversationRecord]] = [:]
        for c in visibleConversations { buckets[ChatSection.of(c.updatedAt, now: now), default: []].append(c) }
        return ChatSection.allCases.compactMap { s in buckets[s].map { (s, $0) } }
    }

    var selected: ConversationRecord? { conversations.first { $0.id == selectedId } }
    var isStreaming: Bool { streaming != nil }
    var unreadCount: Int { conversations.filter(\.unread).count }
    func preview(_ c: ConversationRecord) -> String {
        c.id.flatMap { previews[$0] }.map { Markdown.plainText($0).replacingOccurrences(of: "\n", with: " ") } ?? ""
    }

    /// "Now", "12:04 PM", "Yesterday", "Mon", "Sep 28".
    nonisolated static func shortTime(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if now.timeIntervalSince(d) < 60 { return "Now" }
        if calendar.isDate(d, inSameDayAs: now) { return d.formatted(date: .omitted, time: .shortened) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
        if now.timeIntervalSince(d) < 6 * 86_400 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    func conversation(forBuddy id: Int64?) -> ConversationRecord? { conversations.first { $0.buddyId == id && $0.kind == "buddy" } }

    var draft: String {
        get { selectedId.flatMap { drafts[$0] } ?? newChatDraft }
        set { if let id = selectedId { drafts[id] = newValue } else { newChatDraft = newValue } }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = nil; return }
        searchTask = Task { [db] in
            try? await Task.sleep(nanoseconds: 120_000_000)   // debounce typing
            guard !Task.isCancelled else { return }
            let ids = (try? await db.searchConversationIds(q)) ?? []
            guard !Task.isCancelled else { return }
            self.searchHits = Set(ids)
        }
    }

    private func loadMessages() {
        guard let id = selectedId else { messages = []; return }
        Task {
            let list = (try? await db.messages(conversationId: id)) ?? []
            if self.selectedId == id { self.messages = list }
            if self.selected?.unread == true { try? await db.setUnread(id, false) }
        }
    }

    func newChat() {
        cancel()
        selectedId = nil
        messages = []
    }

    func selectAdjacent(_ delta: Int) {
        let list = visibleConversations
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selectedId } ?? -1
        let next = min(max(idx + delta, 0), list.count - 1)
        selectedId = list[next].id
    }

    func rename(_ c: ConversationRecord, to title: String) {
        guard let id = c.id else { return }
        Task { try? await db.rename(id, title: title) }
    }

    func setArchived(_ c: ConversationRecord, _ v: Bool) {
        guard let id = c.id else { return }
        if v, selectedId == id { selectedId = nil }
        Task { try? await db.setArchived(id, v) }
    }

    func delete(_ c: ConversationRecord) {
        guard let id = c.id else { return }
        if selectedId == id { selectedId = nil }
        drafts[id] = nil
        Task { try? await db.deleteConversation(id) }
    }

    func setFeedback(_ m: MessageRecord, _ value: Int?) {
        var m = m
        m.feedback = value
        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m }
        Task { [m] in try? await db.updateMessage(m) }
    }

    // MARK: Sending

    func send(_ text: String, attachments: [ChatAttachment] = [], includeScreen: Bool = false, tier: ModelTier? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isStreaming else { return }
        errorText = nil
        modelNote = nil
        draft = ""
        if let c = selected, c.kind == "buddy", let bid = c.buddyId, let cid = c.id {
            Task {
                if let m = try? await db.addMessage(MessageRecord(conversationId: cid, role: "user", text: trimmed)) { self.messages.append(m) }
                self.onBuddyTask?(bid, trimmed)
            }
            return
        }
        let names = attachments.map { "📎 \($0.name)" }.joined(separator: "\n")
        let shown = [trimmed, names].filter { !$0.isEmpty }.joined(separator: "\n")
        streaming = StreamingMessage()
        // Look at the screen automatically when the message is about it (no manual screenshot needed).
        let screen = includeScreen || ScreenIntent.mentionsScreen(trimmed)
        task = Task { await self.run(userText: trimmed, shownText: shown, attachments: attachments, includeScreen: screen, tier: tier) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Re-asks the last user message.
    func regenerate() {
        guard !isStreaming, let lastUser = messages.last(where: { $0.role == "user" }), let uid = lastUser.id,
              let cid = selectedId else { return }
        let text = lastUser.text
        Task {
            try? await db.deleteMessages(conversationId: cid, fromId: uid)
            self.messages.removeAll { ($0.id ?? 0) >= uid }
            self.send(text)
        }
    }

    /// Edit & resend: drops the edited message and everything after it, then sends the new text.
    func edit(_ m: MessageRecord, newText: String) {
        guard !isStreaming, let mid = m.id, let cid = selectedId else { return }
        Task {
            try? await db.deleteMessages(conversationId: cid, fromId: mid)
            self.messages.removeAll { ($0.id ?? 0) >= mid }
            self.send(newText)
        }
    }

    private func run(userText: String, shownText: String, attachments: [ChatAttachment], includeScreen: Bool, tier forced: ModelTier?) async {
        defer { streaming = nil; task = nil }
        do {
            var convId = selectedId
            let isNew = convId == nil
            if convId == nil {
                let c = try await db.createConversation(title: "new chat")
                convId = c.id
                selectedId = c.id
            }
            guard let cid = convId else { return }
            let userMsg = try await db.addMessage(MessageRecord(conversationId: cid, role: "user", text: shownText))
            messages.append(userMsg)

            let shot = includeScreen ? try? await capturer.capture(readBrowserURL: settings.data.readBrowserURL) : nil
            var ctx = PromptBuilder.Context(profile: memory.promptProfile, volatile: memory.promptVolatile,
                                            activeSkills: activeSkills(userText),
                                            appName: shot?.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName,
                                            windowTitle: shot?.windowTitle, url: shot?.url)
            ctx.appSkill = skills.skill(bundleID: shot?.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier, url: shot?.url) ?? ""

            // History: last 10 exchanges as text; attachments + screen only on the new turn.
            var turns: [GeminiTurn] = []
            for m in messages.dropLast().suffix(PromptBuilder.maxHistory * 2) {
                turns.append(GeminiTurn(role: m.role == "user" ? .user : .model, text: m.text))
            }
            var textParts = userText
            for a in attachments where !a.isImage && !Self.isInlineDoc(a.mimeType) {
                if let s = String(data: a.data.prefix(200_000), encoding: .utf8) {
                    textParts += "\n\n--- \(a.name) ---\n\(s)"
                }
            }
            let inline = attachments.filter { $0.isImage || Self.isInlineDoc($0.mimeType) }.map { InlinePart(mimeType: $0.mimeType, data: $0.data) }
            turns.append(GeminiTurn(role: .user, text: textParts.isEmpty ? "(see attachment)" : textParts, jpeg: shot?.jpeg, inline: inline))

            usage.configure(prices: settings.data.prices, budget: settings.data.dailyBudgetUSD)
            if usage.meter.status() == .exceeded, settings.data.hardStopAtBudget {
                errorText = "daily budget reached — raise it in settings to keep going"
                return
            }
            var tier = forced ?? ModelRouter.route(userText, mode: settings.data.modelTier)
            if tier == .smart, smartUnavailable { tier = .fast }
            var smart = tier == .smart
            var model = smart ? settings.data.smartModel : settings.data.fastModel
            if !smart, ModelHealth.isBlocked(model) {
                model = settings.data.cheapModel   // known to be out of quota right now: don't wait on it again
                modelNote = "answered by the lite model · fast model hit its free-tier limit"
            }
            var lastUsage: TokenUsage?
            for _ in 0..<3 {
                let req = GeminiRequest(model: model, system: PromptBuilder.system(template: chatTemplate, context: ctx) + PromptBuilder.languageLine(for: userText),
                                        turns: turns, thinkingLevel: smart ? settings.data.smartThinkingLevel : "low",
                                        maxOutputTokens: 8192)
                do {
                    for try await chunk in gemini.stream(req) {
                        if Task.isCancelled { break }
                        if !chunk.text.isEmpty { streaming?.append(chunk.text) }
                        if let u = chunk.usage { lastUsage = u }
                    }
                } catch is CancellationError {
                } catch let e as GeminiError where !smart && model != settings.data.cheapModel
                            && (streaming?.text.isEmpty ?? true) && TalkCoordinator.shouldFallBack(e) {
                    ModelHealth.block(model, for: e)
                    model = settings.data.cheapModel   // fast model limited / overloaded → cheap model
                    modelNote = "answered by the lite model · \(TalkCoordinator.reason(e))"
                    continue
                } catch GeminiError.quotaUnavailable where smart && (streaming?.text.isEmpty ?? true) {
                    smartUnavailable = true
                    smart = false
                    model = settings.data.fastModel
                    modelNote = "answered by the fast model · smart model isn't on your plan"
                    continue   // retry once on the fast model
                } catch {
                    if !Task.isCancelled { errorText = Friendly.message(error) }
                }
                break
            }
            let reply = streaming?.text ?? ""
            if !reply.isEmpty, model == settings.data.fastModel { ModelHealth.succeeded(model) }
            var cost = 0.0
            if let u = lastUsage { cost = usage.record(model: model, usage: u) }
            guard !reply.isEmpty else { return }
            let saved = try await db.addMessage(MessageRecord(conversationId: cid, role: "assistant", text: reply, model: model,
                                                              inputTokens: lastUsage?.inputTokens ?? 0,
                                                              outputTokens: lastUsage?.outputTokens ?? 0, costUSD: cost))
            if selectedId == cid { messages.append(saved) }
            memoryUpdater.record(ConversationTurn(user: userText, assistant: String(reply.prefix(1500))))
            if isNew { Task { await self.generateTitle(cid, user: userText, reply: reply) } }
        } catch {
            errorText = "couldn't save the chat — \(error.localizedDescription)"
        }
    }

    static func isInlineDoc(_ mime: String) -> Bool { mime == "application/pdf" }

    private func generateTitle(_ id: Int64, user: String, reply: String) async {
        let model = settings.data.cheapModel
        let req = GeminiRequest(model: model,
                                system: "Write a 2-5 word lowercase title for this chat. Output only the title, no quotes or punctuation.",
                                turns: [GeminiTurn(role: .user, text: "User: \(user.prefix(400))\nAssistant: \(reply.prefix(400))")],
                                thinkingLevel: "minimal", maxOutputTokens: 20)
        guard let (text, u) = try? await gemini.complete(req) else { return }
        if let u { usage.record(model: model, usage: u) }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.")))
        if !title.isEmpty { try? await db.rename(id, title: String(title.prefix(60))) }
    }

    /// Adds a finished result to a conversation (buddy runs, routines) and marks it unread.
    func appendResult(conversationId cid: Int64, user: String?, text: String, model: String?) {
        Task {
            if let user { _ = try? await db.addMessage(MessageRecord(conversationId: cid, role: "user", text: user)) }
            let m = try? await db.addMessage(MessageRecord(conversationId: cid, role: "assistant", text: text, model: model))
            if selectedId == cid {
                self.messages = (try? await db.messages(conversationId: cid)) ?? self.messages
            } else {
                try? await db.setUnread(cid, true)
            }
            _ = m
        }
    }

    // MARK: Voice turns

    private var voiceConversationId: Int64?

    /// Push-to-talk exchanges are kept (text only) in a per-day "voice" chat.
    func recordVoiceTurn(user: String, assistant: String, model: String, usage u: TokenUsage?, cost: Double) {
        Task {
            do {
                let cid: Int64
                if let id = voiceConversationId, let c = conversations.first(where: { $0.id == id }),
                   Calendar.current.isDateInToday(c.updatedAt) {
                    cid = id
                } else {
                    let f = DateFormatter()
                    f.dateFormat = "MMM d"
                    let c = try await db.createConversation(title: "voice chat · \(f.string(from: Date()).lowercased())", kind: "voice")
                    guard let id = c.id else { return }
                    cid = id
                    voiceConversationId = id
                }
                let um = try await db.addMessage(MessageRecord(conversationId: cid, role: "user", text: user))
                let am = try await db.addMessage(MessageRecord(conversationId: cid, role: "assistant", text: assistant, model: model,
                                                               inputTokens: u?.inputTokens ?? 0, outputTokens: u?.outputTokens ?? 0, costUSD: cost))
                if selectedId == cid { messages += [um, am] }
            } catch {
                Log.app.error("voice turn save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
