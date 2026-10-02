import Foundation

/// A finished exchange kept as text only.
struct ConversationTurn: Sendable, Equatable {
    var user: String
    var assistant: String
}

/// Builds the system prompt and turn list for a talk request.
enum PromptBuilder {
    static let maxHistory = 10

    static func loadTemplate(bundle: Bundle = .main) -> String {
        if let url = bundle.url(forResource: "talk", withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return "You are Sidekick, a friendly, concise AI buddy on the user's Mac. Reply in 1–3 short spoken sentences."
    }

    struct Context {
        var profile = ""
        var volatile = ""
        var activeSkills = ""
        var appSkill = ""
        var appName: String?
        var windowTitle: String?
        var url: String?
    }

    /// A per-turn reply-language line, so skills, memory or on-screen text can't pull replies into another language.
    static func languageLine(for userText: String) -> String {
        let words = userText.split(whereSeparator: { !$0.isLetter }).count
        guard words >= 2 else { return "" }
        switch VoiceSelector.language(of: userText) {
        case "en": return "\nThe user's latest message is in English: reply in English only (no Hindi or Hinglish)."
        case "hinglish": return "\nThe user's latest message is in Hinglish: reply in casual Hinglish (Latin script)."
        case "hi": return "\nThe user's latest message is in Hindi: reply in Hindi."
        default: return ""
        }
    }

    static func system(template: String, context c: Context) -> String {
        func orNone(_ s: String) -> String { s.isEmpty ? "(none)" : s }
        return template
            .replacingOccurrences(of: "{PROFILE}", with: "User profile: " + orNone(c.profile))
            .replacingOccurrences(of: "{VOLATILE}", with: "Current context: " + orNone(c.volatile))
            .replacingOccurrences(of: "{ACTIVE_SKILLS}", with: c.activeSkills.isEmpty ? "" : "Active skills (they never change which language you reply in):\n" + c.activeSkills)
            .replacingOccurrences(of: "{APP_SKILL for current app}", with: c.appSkill.isEmpty ? "" : "App notes:\n" + c.appSkill)
            .replacingOccurrences(of: "{APP}", with: c.appName ?? "unknown")
            .replacingOccurrences(of: "{TITLE}", with: c.windowTitle ?? "unknown")
            .replacingOccurrences(of: "{URL}", with: c.url ?? "none")
    }

    /// Older turns as text only, capped; the latest user turn carries the screenshot.
    static func turns(history: [ConversationTurn], userText: String, screenshot: Data?) -> [GeminiTurn] {
        var out: [GeminiTurn] = []
        for t in history.suffix(maxHistory) {
            out.append(GeminiTurn(role: .user, text: t.user))
            out.append(GeminiTurn(role: .model, text: t.assistant))
        }
        out.append(GeminiTurn(role: .user, text: userText, jpeg: screenshot))
        return out
    }
}
