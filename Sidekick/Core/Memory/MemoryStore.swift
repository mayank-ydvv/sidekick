import Foundation
import Observation

/// Long-term (PROFILE.md) and short-term (VOLATILE.md) memory, as plain markdown files the user can edit.
/// ~/Library/Application Support/Sidekick/Memory/
@MainActor
@Observable
final class MemoryStore {
    static let tokenCapChars = 3200   // ≈ 800 tokens, shared by both files in prompts
    static let volatileDays = 7

    private(set) var profile = ""
    private(set) var volatile = ""
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekick/Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        profile = (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
        volatile = (try? String(contentsOf: volatileURL, encoding: .utf8)) ?? ""
        expireVolatile()
    }

    var profileURL: URL { directory.appendingPathComponent("PROFILE.md") }
    var volatileURL: URL { directory.appendingPathComponent("VOLATILE.md") }

    func setProfile(_ text: String) { profile = text; write(text, to: profileURL) }
    func setVolatile(_ text: String) { volatile = text; write(text, to: volatileURL) }

    /// Applies a model-produced diff to both files. O(lines).
    func apply(_ diff: MemoryDiff) {
        if !diff.profile.isEmpty { setProfile(MemoryDiff.applySectioned(diff.profile, to: profile)) }
        if !diff.volatile.isEmpty { setVolatile(MemoryDiff.apply(diff.volatile, to: volatile, stampDate: Date())) }
    }

    func deleteAll() {
        setProfile("")
        setVolatile("")
    }

    /// Drops VOLATILE lines stamped more than 7 days ago.
    func expireVolatile(now: Date = Date()) {
        let kept = MemoryDiff.expire(volatile, olderThanDays: Self.volatileDays, now: now)
        if kept != volatile { setVolatile(kept) }
    }

    /// Both files, trimmed to the prompt budget (profile gets priority).
    var promptProfile: String { String(profile.prefix(Self.tokenCapChars * 2 / 3)) }
    var promptVolatile: String {
        let room = max(400, Self.tokenCapChars - min(profile.count, Self.tokenCapChars * 2 / 3))
        return String(volatile.suffix(room))
    }

    private func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A minimal line diff the cheap model returns:
///   + profile/preferences: likes short answers      (section: about, work, preferences, people, interests)
///   - profile: <exact line to remove>
///   ~ profile: <old line> => <new line>
///   + volatile: working on the Sidekick app
struct MemoryDiff: Equatable {
    enum Op: Equatable {
        case add(String, section: String? = nil)
        case remove(String)
        case replace(String, String)
    }

    /// PROFILE.md sections, in display order (id used by the model → heading).
    static let sections: [(id: String, title: String)] = [
        ("about", "About me"), ("work", "Work & projects"), ("preferences", "Preferences"),
        ("people", "People"), ("interests", "Interests & habits"),
    ]

    static func sectionTitle(_ id: String?) -> String {
        let i = (id ?? "about").lowercased().trimmingCharacters(in: .whitespaces)
        return sections.first { $0.id == i || $0.title.lowercased() == i || i.hasPrefix($0.id) }?.title ?? "About me"
    }
    var profile: [Op] = []
    var volatile: [Op] = []

    var isEmpty: Bool { profile.isEmpty && volatile.isEmpty }

    static func parse(_ text: String) -> MemoryDiff {
        var d = MemoryDiff()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let sign = line.first, "+-~".contains(sign) else { continue }
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let target: WritableKeyPath<MemoryDiff, [Op]>
            let body: String
            var section: String?
            let lower = rest.lowercased()
            if lower.hasPrefix("profile"), let colon = rest.firstIndex(of: ":") {
                // "profile:", "profile/work:" or "profile (work):"
                let tag = rest[rest.index(rest.startIndex, offsetBy: 7)..<colon]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " /()[]"))
                section = tag.isEmpty ? nil : tag
                target = \.profile; body = String(rest[rest.index(after: colon)...])
            }
            else if lower.hasPrefix("volatile:") { target = \.volatile; body = String(rest.dropFirst(9)) }
            else { continue }
            let b = body.trimmingCharacters(in: .whitespaces)
            guard !b.isEmpty, !containsSecret(b) else { continue }
            switch sign {
            case "+": d[keyPath: target].append(.add(b, section: section))
            case "-": d[keyPath: target].append(.remove(b))
            default:
                let parts = b.components(separatedBy: "=>")
                guard parts.count == 2 else { continue }
                let new = parts[1].trimmingCharacters(in: .whitespaces)
                guard !containsSecret(new) else { continue }
                d[keyPath: target].append(.replace(parts[0].trimmingCharacters(in: .whitespaces), new))
            }
        }
        return d
    }

    /// Applies ops to a markdown bullet list. Matching ignores case, bullets and date stamps.
    static func apply(_ ops: [Op], to text: String, stampDate: Date?) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines == [""] { lines = [] }
        var index: [String: Int] = [:]
        for (i, l) in lines.enumerated() { index[key(l)] = i }
        func bullet(_ raw: String) -> String {
            // The model sometimes copies the "- [date]" format into the fact itself; never stamp twice.
            let s = raw.replacingOccurrences(of: #"^\s*(-\s*)?(\[\d{4}-\d{2}-\d{2}\]\s*)+"#, with: "", options: .regularExpression)
            if let d = stampDate { return "- [\(dayString(d))] \(s)" }
            return "- \(s)"
        }
        for op in ops {
            switch op {
            case .add(let s, _):
                guard index[key(s)] == nil else { continue }
                lines.append(bullet(s))
                index[key(s)] = lines.count - 1
            case .remove(let s):
                if let i = index[key(s)] { lines[i] = "\u{0}"; index[key(s)] = nil }
            case .replace(let old, let new):
                if let i = index[key(old)] {
                    lines[i] = bullet(new); index[key(old)] = nil; index[key(new)] = i
                } else if index[key(new)] == nil {
                    lines.append(bullet(new)); index[key(new)] = lines.count - 1
                }
            }
        }
        return lines.filter { $0 != "\u{0}" }.joined(separator: "\n")
    }

    /// Applies ops to the sectioned PROFILE.md ("## About me", "## Preferences", …). New facts go under their section
    /// (created when needed); removals/edits find the fact in any section. Loose lines from older flat files land in
    /// "About me". Sections are written in a fixed order; empty ones are dropped.
    static func applySectioned(_ ops: [Op], to text: String) -> String {
        var order: [String] = []
        var bySection: [String: [String]] = [:]
        var current = "About me"
        func ensure(_ t: String) { if bySection[t] == nil { bySection[t] = []; order.append(t) } }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                current = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")); ensure(current); continue
            }
            guard !line.isEmpty else { continue }
            ensure(current)
            bySection[current]!.append(line.hasPrefix("- ") || line.hasPrefix("* ") ? "- " + line.dropFirst(2) : "- " + line)
        }
        func locate(_ s: String) -> (String, Int)? {
            for t in order { if let i = bySection[t]!.firstIndex(where: { key($0) == key(s) }) { return (t, i) } }
            return nil
        }
        func bullet(_ s: String) -> String {
            "- " + s.replacingOccurrences(of: #"^\s*(-\s*)?(\[\d{4}-\d{2}-\d{2}\]\s*)+"#, with: "", options: .regularExpression)
        }
        for op in ops {
            switch op {
            case .add(let s, let section):
                guard locate(s) == nil else { continue }
                let t = sectionTitle(section)
                ensure(t)
                bySection[t]!.append(bullet(s))
            case .remove(let s):
                if let (t, i) = locate(s) { bySection[t]!.remove(at: i) }
            case .replace(let old, let new):
                if let (t, i) = locate(old) { bySection[t]![i] = bullet(new) }
                else if locate(new) == nil { ensure("About me"); bySection["About me"]!.append(bullet(new)) }
            }
        }
        let known = sections.map(\.title)
        let ordered = known.filter { order.contains($0) } + order.filter { !known.contains($0) }
        return ordered.compactMap { t -> String? in
            guard let lines = bySection[t], !lines.isEmpty else { return nil }
            return "## \(t)\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func expire(_ text: String, olderThanDays days: Int, now: Date) -> String {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard let d = stamp(String(line)) else { return true }
            return d >= cutoff
        }.joined(separator: "\n")
    }

    /// Normalized identity of a memory line.
    static func key(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s.removeFirst(2) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") { s = String(s[s.index(after: close)...]) }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func stamp(_ line: String) -> Date? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("- ["), let close = s.firstIndex(of: "]") else { return nil }
        let inner = s[s.index(s.startIndex, offsetBy: 3)..<close]
        return dayFormatter.date(from: String(inner))
    }

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Never store secrets: card numbers, passwords, OTP-like codes, API keys.
    static func containsSecret(_ s: String) -> Bool {
        let lower = s.lowercased()
        if ["password", "passcode", "pin is", "otp", "2fa", "cvv", "api key", "secret key", "token:"].contains(where: lower.contains) { return true }
        let digits = s.filter(\.isNumber)
        if digits.count >= 12 { return true }                       // card / account numbers
        if s.range(of: #"\b\d{6}\b"#, options: .regularExpression) != nil, lower.contains("code") { return true }
        if s.range(of: #"(sk|pk|AIza)[A-Za-z0-9_\-]{16,}"#, options: .regularExpression) != nil { return true }
        return false
    }
}
