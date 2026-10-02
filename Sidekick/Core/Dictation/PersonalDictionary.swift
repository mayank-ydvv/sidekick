import Foundation
import Observation

struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String { wrong.lowercased() }
    var wrong: String
    var right: String
    var hits: Int
    var updatedAt: Date
}

/// Learned spelling corrections: used as a Whisper prompt (bias) and as a replacement map.
/// Persisted as JSON for now (moves to the GRDB `dictionary` table in Phase 5).
@MainActor
@Observable
final class PersonalDictionary {
    private(set) var entries: [DictionaryEntry] = []
    private let url: URL
    private let db: AppDatabase?

    /// With a database, entries live in the `dictionary` table; a legacy JSON file is imported once.
    init(url: URL? = nil, db: AppDatabase? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekick/dictionary.json")
        self.db = db
        let legacy = (try? Data(contentsOf: self.url)).flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) } ?? []
        if let db {
            let rows = (try? db.dictionaryEntries()) ?? []
            entries = rows.map { DictionaryEntry(wrong: $0.wrong, right: $0.right, hits: $0.hits, updatedAt: $0.updatedAt) }
            if !legacy.isEmpty {
                for e in legacy where !entries.contains(where: { $0.id == e.id }) { entries.append(e) }
                save()
                try? FileManager.default.removeItem(at: self.url)
            }
        } else {
            entries = legacy
        }
    }

    func learn(wrong: String, right: String) {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty, w != r else { return }
        if let i = entries.firstIndex(where: { $0.wrong.lowercased() == w.lowercased() }) {
            entries[i].right = r
            entries[i].hits += 1
            entries[i].updatedAt = Date()
        } else {
            entries.append(DictionaryEntry(wrong: w, right: r, hits: 1, updatedAt: Date()))
        }
        save()
    }

    func remove(_ e: DictionaryEntry) {
        entries.removeAll { $0.id == e.id }
        if let db { Task.detached { try? await db.deleteDictionary(wrong: e.wrong) } }
        save()
    }

    func removeAll() {
        let old = entries
        entries = []
        if let db { Task.detached { for e in old { try? await db.deleteDictionary(wrong: e.wrong) } } }
        save()
    }

    /// Up to ~40 distinct correct spellings, most-used first, for Whisper's initial prompt.
    var promptWords: String {
        var seen = Set<String>()
        return entries.sorted { $0.hits > $1.hits }
            .map(\.right)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(40)
            .joined(separator: ", ")
    }

    func apply(_ text: String) -> String { Self.apply(entries, to: text) }

    /// Whole-word, case-insensitive replacement in a single regex pass.
    nonisolated static func apply(_ entries: [DictionaryEntry], to text: String) -> String {
        guard !entries.isEmpty else { return text }
        var map: [String: String] = [:]
        for e in entries { map[e.wrong.lowercased()] = e.right }
        let alternation = map.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alternation))(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let found = ns.substring(with: m.range).lowercased()
            out += map[found] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private func save() {
        if let db {
            let rows = entries.map { DictionaryRecord(id: nil, wrong: $0.wrong, right: $0.right, hits: $0.hits, updatedAt: $0.updatedAt) }
            Task.detached { for r in rows { try? await db.upsertDictionary(r) } }
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

/// Figures out whether the user corrected a word we inserted. Pure; works in UTF-16 offsets (AX ranges).
enum CorrectionLearner {
    /// - Parameters:
    ///   - before: field value right after our insertion
    ///   - after: field value now
    ///   - inserted: UTF-16 range of the text we inserted, within `before`
    static func learn(before: String, after: String, inserted: NSRange) -> (wrong: String, right: String)? {
        let a = Array(before.utf16), b = Array(after.utf16)
        guard a != b else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }

        // Expand the changed span to whole words in both strings.
        func isWordChar(_ u: UInt16) -> Bool {
            guard let sc = Unicode.Scalar(u) else { return true }   // surrogate halves count as word chars
            return CharacterSet.alphanumerics.contains(sc) || u == 0x27 || u == 0x2D   // ' and -
        }
        var start = p
        while start > 0, isWordChar(a[start - 1]) { start -= 1 }
        var endA = a.count - s, endB = b.count - s
        while endA < a.count, isWordChar(a[endA]) { endA += 1; endB += 1 }
        guard start <= endA, start <= endB, endB <= b.count else { return nil }

        // The edit must be inside what we inserted.
        guard start >= inserted.location, endA <= inserted.location + inserted.length else { return nil }

        let wrong = String(utf16CodeUnits: Array(a[start..<endA]), count: endA - start)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(utf16CodeUnits: Array(b[start..<endB]), count: endB - start)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return nil }
        let wc = wrong.split(separator: " ").count, rc = right.split(separator: " ").count
        guard wc <= 3, rc <= 3 else { return nil }
        // Corrections are small fixes, not rewrites.
        let dist = levenshtein(Array(wrong.lowercased()), Array(right.lowercased()))
        guard dist <= max(2, Int(Double(max(wrong.count, right.count)) * 0.6)) else { return nil }
        return (wrong, right)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
