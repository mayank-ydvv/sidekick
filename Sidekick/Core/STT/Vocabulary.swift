import CoreGraphics
import Foundation
import Vision

/// Words Whisper should expect — names visible on screen ("Ravi Sharma" in a chat list), names from memory and
/// the personal dictionary — passed as a short prompt so it spells them right instead of guessing ("ravisharma").
enum Vocabulary {
    /// UI chrome and common words that are capitalized on screen but never worth biasing toward.
    static let ignore: Set<String> = [
        "the", "and", "for", "you", "your", "with", "this", "that", "from", "file", "edit", "view", "window", "help",
        "history", "bookmarks", "go", "tools", "format", "insert", "search", "chats", "chat", "all", "unread", "today",
        "yesterday", "new", "open", "close", "save", "share", "settings", "more", "photo", "video", "message", "messages",
        "calls", "updates", "communities", "media", "favourites", "favorites", "groups", "online", "typing", "you're",
        "reply", "send", "home", "back", "next", "done", "cancel", "delete", "add", "menu", "tab", "tabs", "page",
        "mon", "tue", "wed", "thu", "fri", "sat", "sun", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "now", "ill",
        "starred", "voice", "version", "pro", "beta", "code", "web", "first", "starting", "getting", "customize", "hey",
    ]

    /// The first recognition loads Vision's text model (can take many seconds); do it once at launch, off the main thread.
    static func prewarm() {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        if let img = ctx?.makeImage() { _ = fromScreen(img) }
    }

    /// Recognizes text in the screenshot (accurate mode; runs while the user is still speaking) and keeps name-like phrases: 1–3 capitalized words.
    static func fromScreen(_ image: CGImage, limit: Int = 40) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return names(in: lines, limit: limit)
    }

    /// Pure: name-like phrases from text lines, most frequent first, deduplicated.
    static func names(in lines: [String], limit: Int = 40) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        // Punctuation, digits and wide gaps end a name ("Priya Mehta, Ravi Sharma" is two names).
        let segments = lines.flatMap { line in
            line.replacingOccurrences(of: "  ", with: "|")
                .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" && $0 != " " }).map(String.init)
        }
        for segment in segments {
            let words = segment.split(separator: " ").map(String.init)
            var run: [String] = []
            func flush() {
                defer { run = [] }
                guard !run.isEmpty else { return }
                let phrase = run.prefix(3).joined(separator: " ")
                if counts[phrase] == nil { order.append(phrase) }
                counts[phrase, default: 0] += 1
            }
            for w in words {
                let isName = w.count >= 3 && (w.first?.isUppercase ?? false) && !ignore.contains(w.lowercased())
                    && !w.hasPrefix("I'") && !w.contains("'II")
                    && !(w.count > 3 && w.allSatisfy { $0.isUppercase })   // skip SHOUTING UI labels
                if isName { run.append(w) } else { flush() }
            }
            flush()
        }
        return order.sorted { (counts[$0]!, $0.split(separator: " ").count) > (counts[$1]!, $1.split(separator: " ").count) }
            .prefix(limit).map { $0 }
    }

    /// The Whisper prompt: a short comma list (Whisper only uses ~200 tokens of prompt).
    static func prompt(screen: [String], memory: [String], dictionary: [String]) -> String? {
        var seen = Set<String>()
        var out: [String] = []
        for w in ["Sidekick"] + dictionary + memory + screen where !w.isEmpty && seen.insert(w.lowercased()).inserted {
            out.append(w)
            if out.joined(separator: ", ").count > 300 { out.removeLast(); break }
        }
        return out.count > 1 ? out.joined(separator: ", ") + "." : nil
    }

    /// Name-like words from the user's memory profile (People / About me lines).
    static func fromMemory(_ profile: String) -> [String] {
        names(in: profile.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }, limit: 20)
            .filter { !["Name", "Prefers", "Likes", "Loves", "Studies", "Works", "Building"].contains($0.split(separator: " ").first.map(String.init) ?? "") }
    }
}
