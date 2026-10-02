import Foundation

/// Incremental splitter for streamed model output.
/// Feed text deltas with `push`; it returns complete, speech-ready sentences.
/// Tags like `[POINT ...]`, markdown symbols and URLs are removed from spoken text.
/// Each character is processed once, so total work is O(n) over the stream.
struct SentenceSplitter {
    private var current = ""          // speech text of the in-progress sentence
    private var inTag = false
    private var pendingBoundary = false
    private var word = ""             // current token, used to detect URLs
    private var emitted = 0
    /// Chars needed before a comma/colon/semicolon may end a chunk. Small for the first chunk
    /// so speech starts sooner; larger afterwards so prosody stays natural.
    static let firstClauseMin = 24
    static let laterClauseMin = 110

    init() {}

    mutating func push(_ delta: String) -> [String] {
        var out: [String] = []
        for ch in delta {
            if inTag {
                if ch == "]" { inTag = false }
                continue
            }
            if pendingBoundary {
                pendingBoundary = false
                if ch.isWhitespace || ch.isNewline {
                    flushWord()
                    if let s = take() { out.append(s) }
                    continue
                }
            }
            switch ch {
            case "[":
                flushWord()
                inTag = true
            case "*", "#", "`", "_", "~", ">", "|":
                continue
            case "\n":
                flushWord()
                if let s = take() { out.append(s) }
            case ".", "!", "?", "…", "।":
                word.append(ch)
                pendingBoundary = true
            case ",", ";", ":", "—":
                word.append(ch)
                let min = emitted == 0 ? Self.firstClauseMin : Self.laterClauseMin
                if current.count + word.count >= min { pendingBoundary = true }
            default:
                if ch.isWhitespace {
                    flushWord()
                    current.append(" ")
                } else {
                    word.append(ch)
                }
            }
        }
        return out
    }

    /// Call at end of stream to get any remaining text.
    mutating func finish() -> String? {
        flushWord()
        pendingBoundary = false
        inTag = false
        return take()
    }

    private mutating func flushWord() {
        guard !word.isEmpty else { return }
        current.append(Self.isURL(word) ? "link" : word)
        word = ""
    }

    private mutating func take() -> String? {
        let s = current.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        current = ""
        if !s.isEmpty { emitted += 1 }
        return s.isEmpty ? nil : s
    }

    static func isURL(_ w: String) -> Bool {
        let lower = w.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
    }

    /// Removes `[...]` tags from display text (non-incremental helper).
    static func stripTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var depth = false
        for ch in s {
            if ch == "[" { depth = true; continue }
            if depth { if ch == "]" { depth = false }; continue }
            out.append(ch)
        }
        return out
    }
}
