import Foundation

/// After conversations, asks the cheap model for a minimal diff to PROFILE.md / VOLATILE.md.
/// Debounced 30 s (2 s when the user explicitly asks to remember/forget something).
@MainActor
final class MemoryUpdater {
    static let debounce: TimeInterval = 30
    static let urgentDebounce: TimeInterval = 2
    nonisolated static let urgentPhrases = ["remember", "forget", "my name is", "call me", "i prefer", "i like", "keep answers",
                                "keep it short", "don't ", "do not ", "always ", "never ", "mera naam", "yaad rakh"]

    private let memory: MemoryStore
    private let gemini: GeminiClient
    private let settings: AppSettings
    private let usage: UsageStore
    private var pending: [ConversationTurn] = []
    private var work: DispatchWorkItem?
    private var running = false

    init(memory: MemoryStore, gemini: GeminiClient, settings: AppSettings, usage: UsageStore) {
        self.memory = memory
        self.gemini = gemini
        self.settings = settings
        self.usage = usage
    }

    func record(_ turn: ConversationTurn) {
        pending.append(turn)
        if pending.count > 30 { pending.removeFirst(pending.count - 30) }
        let urgent = Self.isUrgent(turn.user)
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { await self?.run() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (urgent ? Self.urgentDebounce : Self.debounce), execute: w)
    }

    nonisolated static func isUrgent(_ text: String) -> Bool {
        let t = text.lowercased()
        return urgentPhrases.contains(where: t.contains)
    }

    private func run() async {
        guard !running, !pending.isEmpty else { return }
        running = true
        defer { running = false }
        let turns = pending
        pending = []
        let transcript = turns.map { "User: \($0.user)\nSidekick: \($0.assistant)" }.joined(separator: "\n\n")
        let system = Self.instructions
        let user = """
        PROFILE.md:
        \(memory.profile.isEmpty ? "(empty)" : memory.profile)

        VOLATILE.md:
        \(memory.volatile.isEmpty ? "(empty)" : memory.volatile)

        Conversation:
        \(transcript)
        """
        let model = settings.data.cheapModel
        let req = GeminiRequest(model: model, system: system, turns: [GeminiTurn(role: .user, text: user)],
                                thinkingLevel: "off", maxOutputTokens: 512)
        do {
            let (text, u) = try await gemini.complete(req)
            if let u { usage.record(model: model, usage: u) }
            let diff = MemoryDiff.parse(text)
            if !diff.isEmpty {
                memory.apply(diff)
                Log.app.info("memory updated (\(diff.profile.count + diff.volatile.count) changes)")
            }
        } catch {
            // Try again with the next conversation.
            pending = turns + pending
            Log.app.error("memory update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let instructions = """
    You maintain two short memory files about the user of a Mac assistant.
    PROFILE.md = long-term facts: name, languages, job, preferences, writing style, how they like answers.
    VOLATILE.md = current projects and short-term context (expires after a week).
    PROFILE.md is organised into sections: about (name, languages, location, background), work (job, studies, ongoing
    projects), preferences (how they like answers, tools, style), people (friends, family, colleagues they mention),
    interests (hobbies, music, habits).
    Read the conversation and output ONLY the minimal changes, one per line, in this exact format:
    + profile/<section>: <new fact>          e.g.  + profile/preferences: Prefers step-by-step math answers
    - profile: <exact existing line text to remove>
    ~ profile: <exact existing line text> => <updated fact>
    + volatile: <short-term context>         (also "- volatile:" and "~ volatile:")
    Rules: keep each fact under 15 words, written in third person ("Prefers short answers").
    ONLY store what the USER explicitly said about themselves or asked for. Never infer preferences from how Sidekick replied
    (e.g. the language Sidekick happened to answer in) or from what was on their screen. One-off requests ("talk slower" for this answer) are not lasting preferences unless the user says "always" / "from now on".
    Only store things useful later. If the user says "forget …", remove it. If nothing should change, output nothing.
    NEVER store passwords, card or account numbers, codes, API keys, or other secrets.
    """
}
