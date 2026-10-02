import Foundation

/// Fast, local cleanup for dictated text. Pure; O(n).
enum TextCleaner {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm"]

    /// Spoken punctuation/commands → symbols. Longest phrases first.
    static let spoken: [(String, String)] = [
        ("new paragraph", "\n\n"), ("new line", "\n"), ("next line", "\n"),
        ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
        ("full stop", "."), ("period", "."), ("comma", ","), ("colon", ":"), ("semicolon", ";"),
    ]

    static func clean(_ input: String) -> String {
        var words = tokenize(input)
        // 1) Spoken commands (matched case-insensitively, ignoring punctuation Whisper glued on).
        var out: [String] = []
        var i = 0
        outer: while i < words.count {
            for (phrase, symbol) in spoken {
                let parts = phrase.split(separator: " ").map(String.init)
                if i + parts.count <= words.count,
                   zip(parts, words[i..<(i + parts.count)]).allSatisfy({ $0 == bare($1) }) {
                    out.append(symbol)
                    i += parts.count
                    continue outer
                }
            }
            if !fillers.contains(bare(words[i])) { out.append(words[i]) }
            i += 1
        }
        words = out
        // 2) Join, attaching punctuation tokens to the previous word.
        var text = ""
        for w in words {
            if w == "\n" || w == "\n\n" {
                text = trimTrailingSpaces(text) + w
            } else if [".", ",", "?", "!", ":", ";"].contains(w) {
                text = trimTrailingSpaces(text)
                // Replace punctuation Whisper already added ("hello, comma" → "hello,").
                if let last = text.last, ".,?!:;".contains(last) { text.removeLast() }
                text += w
            } else {
                if !text.isEmpty, !(text.last?.isNewline ?? false) { text += " " }
                text += w
            }
        }
        // 3) Tidy: drop stray commas left by removed fillers, capitalize sentence starts.
        text = text.replacingOccurrences(of: " ,", with: ",")
        while text.contains(",,") { text = text.replacingOccurrences(of: ",,", with: ",") }
        if text.hasPrefix(",") { text.removeFirst() }
        return capitalizeSentences(text.trimmingCharacters(in: .whitespaces))
    }

    private static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Lowercased word without surrounding punctuation.
    static func bare(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func trimTrailingSpaces(_ s: String) -> String {
        var t = s
        while t.last == " " { t.removeLast() }
        return t
    }

    static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter {
                out += ch.uppercased()
                capNext = false
                continue
            }
            out.append(ch)
            if ".?!\n".contains(ch) { capNext = true }
            else if !ch.isWhitespace { capNext = false }
        }
        return out
    }
}
