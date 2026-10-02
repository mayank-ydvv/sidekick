import Foundation

/// Block-level markdown, parsed once per message (cached) and incrementally while streaming.
enum MDBlock: Equatable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [String])
    case numbered(start: Int, items: [String])
    case quote(String)
    case code(language: String?, code: String, closed: Bool)
    case table(header: [String], rows: [[String]])
    case rule
}

enum Markdown {
    /// Parses a full document. O(n) over lines.
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = MathText.clean(text).components(separatedBy: "\n")
        var i = 0
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("```") {
                flushPara()
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                var closed = false
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { closed = true; break }
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n"), closed: closed))
                i += 1
                continue
            }
            if t.isEmpty { flushPara(); i += 1; continue }
            if t == "---" || t == "***" || t == "___" { flushPara(); blocks.append(.rule); i += 1; continue }
            if let h = heading(t) { flushPara(); blocks.append(h); i += 1; continue }
            if t.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(q.joined(separator: "\n")))
                continue
            }
            if bulletItem(t) != nil {
                flushPara()
                var items: [String] = []
                while i < lines.count, let item = bulletItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(item); i += 1
                    // Continuation lines (indented, non-list) belong to the previous item.
                    while i < lines.count, lines[i].hasPrefix("  "), bulletItem(lines[i].trimmingCharacters(in: .whitespaces)) == nil,
                          numberedItem(lines[i].trimmingCharacters(in: .whitespaces)) == nil, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        items[items.count - 1] += " " + lines[i].trimmingCharacters(in: .whitespaces); i += 1
                    }
                }
                blocks.append(.bullet(items: items))
                continue
            }
            if let first = numberedItem(t) {
                flushPara()
                var items: [String] = []
                while i < lines.count, let item = numberedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(item.1); i += 1
                }
                blocks.append(.numbered(start: first.0, items: items))
                continue
            }
            if t.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushPara()
                let header = cells(t)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            para.append(line)
            i += 1
        }
        flushPara()
        return blocks
    }

    static func heading(_ t: String) -> MDBlock? {
        var level = 0
        for ch in t { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), t.count > level, t[t.index(t.startIndex, offsetBy: level)] == " " else { return nil }
        return .heading(level: level, text: String(t.dropFirst(level + 1)))
    }

    static func bulletItem(_ t: String) -> String? {
        for p in ["- ", "* ", "• "] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return nil
    }

    static func numberedItem(_ t: String) -> (Int, String)? {
        guard let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), dot > t.startIndex,
              let n = Int(t[..<dot]), t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " " else { return nil }
        return (n, String(t[t.index(dot, offsetBy: 2)...]))
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Plain text for read-aloud / copy-as-text.
    static func plainText(_ text: String) -> String {
        var out = text
        for s in ["```", "**", "__", "`", "#"] { out = out.replacingOccurrences(of: s, with: "") }
        return out
    }
}

/// Streaming-friendly parser: blocks that can no longer change are frozen;
/// only the open tail is re-parsed on each append (O(chunk + tail), not O(message)).
struct IncrementalMarkdown {
    private(set) var stable: [MDBlock] = []
    private(set) var tail = ""
    private(set) var tailBlocks: [MDBlock] = []

    var blocks: [MDBlock] { stable + tailBlocks }

    mutating func append(_ chunk: String) {
        tail += chunk
        // Freeze everything up to the last blank line that is outside a code fence.
        if let cut = Self.safeBoundary(in: tail) {
            let head = String(tail[..<cut])
            stable += Markdown.parse(head)
            tail = String(tail[cut...])
        }
        tailBlocks = Markdown.parse(tail)
    }

    static func safeBoundary(in s: String) -> String.Index? {
        var inFence = false
        var lastSafe: String.Index?
        var lineStart = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\n" {
                let line = s[lineStart..<i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") { inFence.toggle() }
                let next = s.index(after: i)
                // A blank line (\n\n) outside a fence ends the previous block.
                if !inFence, next < s.endIndex, s[next] == "\n" { lastSafe = s.index(after: next) }
                lineStart = next
            }
            i = s.index(after: i)
        }
        return lastSafe
    }
}

/// Tiny regex-based syntax highlighter: comments, strings, numbers, keywords.
enum SyntaxHighlighter {
    enum Kind { case keyword, string, comment, number }

    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case",
        "switch", "guard", "in", "self", "true", "false", "nil", "null", "none", "def", "const", "function", "async",
        "await", "try", "catch", "throw", "throws", "public", "private", "static", "extension", "protocol", "new",
        "from", "export", "default", "interface", "type", "fn", "pub", "impl", "use", "mut", "match", "elif", "and",
        "or", "not", "is", "lambda", "with", "as", "package", "go", "select", "SELECT", "FROM", "WHERE", "JOIN",
        "INSERT", "UPDATE", "DELETE", "CREATE", "TABLE", "echo", "then", "fi", "do", "done",
    ]

    static let pattern = try! NSRegularExpression(pattern: #"(//[^\n]*|#(?!include)[^\n]*|/\*[\s\S]*?\*/)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`[^`]*`)|\b(\d+(?:\.\d+)?)\b|\b([A-Za-z_][A-Za-z0-9_]*)\b"#)

    /// Returns (UTF-16 range, kind) spans. `#` comments only for languages that use them.
    static func spans(_ code: String, language: String?) -> [(NSRange, Kind)] {
        let hashComments = ["python", "py", "bash", "sh", "zsh", "ruby", "rb", "yaml", "yml", "toml", "shell"].contains(language?.lowercased() ?? "")
        var out: [(NSRange, Kind)] = []
        let ns = code as NSString
        for m in pattern.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                let r = m.range(at: 1)
                if ns.substring(with: r).hasPrefix("#"), !hashComments { continue }
                out.append((r, .comment))
            } else if m.range(at: 2).location != NSNotFound {
                out.append((m.range(at: 2), .string))
            } else if m.range(at: 3).location != NSNotFound {
                out.append((m.range(at: 3), .number))
            } else if m.range(at: 4).location != NSNotFound, keywords.contains(ns.substring(with: m.range(at: 4))) {
                out.append((m.range(at: 4), .keyword))
            }
        }
        return out
    }
}
