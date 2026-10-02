import SwiftUI

/// Everything the chat views need, passed down once.
@MainActor
struct ChatContext {
    let store: ChatStore
    let ui: NotchUIState
    let controller: NotchController?
    let settings: AppSettings
    let memory: MemoryStore
    let buddies: BuddyStore
    let wiki: NotesWiki
    let suggester: ProactiveSuggester
    let runTask: (String) -> Void
    let readAloud: (String) -> Void
    let openSettings: () -> Void
    /// Records while held; returns the transcript.
    let micStart: () -> Void
    let micStop: () async -> String?
    let micLevel: () -> Float
}

enum Suggestions {
    /// Four starter prompts based on the frontmost app.
    static func forApp(_ bundleID: String?, name: String?) -> [String] {
        let app = name ?? "this app"
        switch bundleID ?? "" {
        case "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode":
            return ["explain the code on my screen", "find the bug in this file", "write tests for this", "what does this error mean?"]
        case "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser":
            return ["summarize this page", "what are the key points here?", "draft a reply to this", "explain this like i'm new"]
        case "com.tinyspeck.slackmacgap", "com.apple.mail":
            return ["help me reply to this", "summarize this thread", "make my message friendlier", "what should i prioritize?"]
        case "com.figma.Desktop", "com.adobe.Photoshop", "com.canva.CanvaDesktop":
            return ["give me feedback on this design", "how do i make a component?", "suggest a color palette", "teach me a shortcut"]
        default:
            return ["what's on my screen?", "teach me something in \(app)", "plan my day", "write a quick note for me"]
        }
    }
}

extension MemoryStore {
    /// First name from a "name: X" / "Name is X" profile line, for the greeting.
    var userName: String? {
        for line in profile.split(separator: "\n") {
            let l = line.lowercased()
            for key in ["name:", "name is", "called "] {
                if let r = l.range(of: key) {
                    let rest = line[line.index(line.startIndex, offsetBy: l.distance(from: l.startIndex, to: r.upperBound))...]
                    let word = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                        .split(separator: " ").first.map(String.init)
                    if let word, !word.isEmpty { return word }
                }
            }
        }
        return nil
    }
}
