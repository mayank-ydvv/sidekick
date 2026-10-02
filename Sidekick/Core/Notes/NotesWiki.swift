import Foundation
import Observation

/// "Save this…" → one markdown file per topic in ~/Sidekick/Notes/, with [[links]] between topics.
@MainActor
@Observable
final class NotesWiki {
    private(set) var topics: [String] = []
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sidekick/Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        topics = files.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    func url(for topic: String) -> URL {
        directory.appendingPathComponent(FileTools.safeName(topic, ext: "md"))
    }

    func read(_ topic: String) -> String { (try? String(contentsOf: url(for: topic), encoding: .utf8)) ?? "" }

    /// Creates or appends to a topic page and links mentions of other topics. Returns the file.
    @discardableResult
    func save(topic: String, content: String, append: Bool = true) -> URL {
        let file = url(for: topic)
        let linked = Self.autoLink(content, topics: topics.filter { $0.lowercased() != topic.lowercased() })
        var text: String
        if append, FileManager.default.fileExists(atPath: file.path) {
            text = read(topic) + "\n\n" + linked
        } else {
            text = "# \(topic)\n\n" + linked
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        text += "\n\n_updated \(df.string(from: Date()))_\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
        reload()
        return file
    }

    func search(_ q: String) -> [String] {
        let query = q.lowercased()
        return topics.filter { $0.lowercased().contains(query) || read($0).lowercased().contains(query) }
    }

    /// Wraps the first plain mention of each existing topic in [[…]] (case-insensitive, whole words, not inside existing links).
    nonisolated static func autoLink(_ text: String, topics: [String]) -> String {
        var out = text
        for topic in topics.sorted(by: { $0.count > $1.count }) where !topic.isEmpty {
            if out.range(of: "[[\(topic)]]", options: .caseInsensitive) != nil { continue }
            let pattern = "(?<![\\[\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: topic) + "(?![\\]\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: "[[\(out[r])]]")
        }
        return out
    }
}
