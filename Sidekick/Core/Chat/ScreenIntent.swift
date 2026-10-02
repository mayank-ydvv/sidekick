import Foundation

/// Decides whether a typed chat message is about what's on the user's screen, so the screen is
/// captured automatically (the user never has to attach a screenshot themselves).
enum ScreenIntent {
    /// Phrases that clearly point at the screen.
    static let phrases = [
        "screen", "screenshot", "on my display", "in front of me", "i'm looking at", "im looking at", "i am looking at",
        "this page", "this tab", "this window", "this site", "this website", "this article", "this pdf", "this doc",
        "this question", "these questions", "this problem", "this exercise", "this code", "this error", "this message",
        "this email", "this image", "this picture", "this chart", "this graph", "this table", "this form", "this app",
        "this text", "this paragraph", "this answer", "this one", "this video", "what's this", "whats this", "what is this",
        "what am i looking at", "visible", "shown here", "showing", "on the page", "on this", "above", "highlighted",
        "selected", "open here", "here on", "the question", "first question", "second question", "last question",
        "question no", "question number", "q1", "q2", "q3", "q 1", "q 2", "solve this", "explain this", "read this",
        "summarize this", "summarise this", "translate this", "fix this", "check this", "look at", "can you see",
        "do you see", "you see",
    ]

    static func mentionsScreen(_ text: String) -> Bool {
        let t = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        if phrases.contains(where: { t.contains($0) }) { return true }
        // Short imperative about "this"/"it" with nothing else to go on (e.g. "solve it", "explain").
        let words = t.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let verbs: Set<String> = ["solve", "explain", "summarize", "summarise", "translate", "answer", "fix", "debug", "review", "proofread"]
        return words.count <= 4 && words.contains(where: verbs.contains)
    }
}
