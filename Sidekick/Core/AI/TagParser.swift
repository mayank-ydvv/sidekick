import Foundation

/// A drawing/control instruction the model emits inline, e.g. `[POINT y=412 x=733 label="Export"]`.
/// Coordinates are Gemini-native: normalized 0–1000, y first.
enum OverlayTag: Equatable, Sendable {
    case point(y: Double, x: Double, label: String?)
    case circle(y: Double, x: Double, r: Double?, label: String?)
    case arrow(fromY: Double, fromX: Double, toY: Double, toX: Double, label: String?)
    case highlight(y1: Double, x1: Double, y2: Double, x2: Double, label: String?)
    case step(n: Int, of: Int?)
    case waitClick
    case escalate
    case agent(task: String)
    case type(text: String)
    case setting(key: String, value: String)
}

enum ParsedEvent: Equatable, Sendable {
    case text(String)
    case tag(OverlayTag)
}

/// Single-pass streaming tag parser. Tolerates tags split across chunks, quoted values
/// containing `]`, and malformed tags (dropped, never crashes). O(n) over the stream.
struct TagParser {
    static let maxTagLength = 600

    private var inTag = false
    private var inQuote = false
    private var escaped = false
    private var buffer = ""

    init() {}

    mutating func push(_ chunk: String) -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        var text = ""
        func flushText() {
            if !text.isEmpty { events.append(.text(text)); text = "" }
        }
        for ch in chunk {
            if !inTag {
                if ch == "[" {
                    inTag = true
                    buffer = ""
                } else {
                    text.append(ch)
                }
                continue
            }
            // Inside a tag.
            if inQuote {
                buffer.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inQuote = false }
            } else if ch == "\"" {
                inQuote = true
                buffer.append(ch)
            } else if ch == "]" {
                inTag = false
                if let tag = Self.parse(buffer) {
                    flushText()
                    events.append(.tag(tag))
                }
                buffer = ""
            } else if ch == "[" {
                // Unbalanced: drop what we had and start a new tag.
                buffer = ""
            } else {
                buffer.append(ch)
            }
            if inTag, buffer.count > Self.maxTagLength {
                inTag = false; inQuote = false; escaped = false; buffer = ""
            }
        }
        flushText()
        return events
    }

    /// End of stream: an unclosed tag is discarded.
    mutating func finish() -> [ParsedEvent] {
        inTag = false; inQuote = false; escaped = false; buffer = ""
        return []
    }

    // MARK: Tag body parsing

    static func parse(_ body: String) -> OverlayTag? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nameEnd = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let name = trimmed[..<nameEnd].uppercased()
        let attrs = attributes(String(trimmed[nameEnd...]))
        func num(_ k: String) -> Double? { attrs[k].flatMap(number) }
        let label = attrs["label"].flatMap { $0.isEmpty ? nil : $0 }

        switch name {
        case "POINT":
            guard let y = num("y"), let x = num("x") else { return nil }
            return .point(y: y, x: x, label: label)
        case "CIRCLE":
            guard let y = num("y"), let x = num("x") else { return nil }
            return .circle(y: y, x: x, r: num("r"), label: label)
        case "ARROW":
            guard let fy = num("from_y"), let fx = num("from_x"), let ty = num("to_y"), let tx = num("to_x") else { return nil }
            return .arrow(fromY: fy, fromX: fx, toY: ty, toX: tx, label: label)
        case "HIGHLIGHT":
            guard let y1 = num("y1"), let x1 = num("x1"), let y2 = num("y2"), let x2 = num("x2") else { return nil }
            return .highlight(y1: y1, x1: x1, y2: y2, x2: x2, label: label)
        case "STEP":
            guard let n = num("n") else { return nil }
            return .step(n: Int(n), of: num("of").map { Int($0) })
        case "WAIT_CLICK": return .waitClick
        case "ESCALATE": return .escalate
        case "AGENT":
            guard let t = attrs["task"], !t.isEmpty else { return nil }
            return .agent(task: t)
        case "TYPE":
            guard let t = attrs["text"] else { return nil }
            return .type(text: t)
        case "SETTING":
            guard let k = attrs["key"], let v = attrs["value"] else { return nil }
            return .setting(key: k, value: v)
        default:
            return nil
        }
    }

    /// Parses `key=value key="quoted value"` pairs. Keys are lowercased.
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        func skipSpace() { while i < s.endIndex, s[i].isWhitespace || s[i] == "," { i = s.index(after: i) } }
        while true {
            skipSpace()
            guard i < s.endIndex else { break }
            let keyStart = i
            while i < s.endIndex, s[i] != "=", !s[i].isWhitespace { i = s.index(after: i) }
            let key = s[keyStart..<i].lowercased()
            guard i < s.endIndex, s[i] == "=" else { continue }
            i = s.index(after: i)
            var value = ""
            if i < s.endIndex, s[i] == "\"" || s[i] == "'" {
                let q = s[i]
                i = s.index(after: i)
                var esc = false
                while i < s.endIndex {
                    let c = s[i]
                    i = s.index(after: i)
                    if esc { value.append(c); esc = false; continue }
                    if c == "\\" { esc = true; continue }
                    if c == q { break }
                    value.append(c)
                }
            } else {
                while i < s.endIndex, !s[i].isWhitespace { value.append(s[i]); i = s.index(after: i) }
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;)("))
        guard let v = Double(t), v.isFinite else { return nil }
        return v
    }
}
