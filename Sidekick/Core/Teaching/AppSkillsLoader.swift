import Foundation

/// App skills: markdown notes about an app/site, injected when it's frontmost.
/// Files declare what they match in frontmatter:
/// ---
/// name: Finder
/// match: com.apple.finder
/// ---
/// User files in ~/Library/Application Support/Sidekick/AppSkills override bundled ones.
final class AppSkillsLoader: @unchecked Sendable {
    static let maxChars = 2200

    private let lock = NSLock()
    private var index: [String: URL] = [:]   // lowercased bundle id or domain → file
    private var cache: [URL: String] = [:]
    private var loaded = false
    private let directories: [URL]

    init(directories: [URL]? = nil) {
        if let directories {
            self.directories = directories
        } else {
            var dirs: [URL] = []
            if let res = Bundle.main.resourceURL { dirs.append(res) }
            dirs.append(Self.userDirectory)
            self.directories = dirs
        }
    }

    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekick/AppSkills", isDirectory: true)
    }

    /// Builds the match index once (later directories override earlier ones).
    private func loadIndex() {
        guard !loaded else { return }
        loaded = true
        for dir in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension.lowercased() == "md" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for key in Self.matchKeys(in: text) { index[key] = f }
            }
        }
    }

    func reload() {
        lock.lock(); defer { lock.unlock() }
        loaded = false
        index = [:]
        cache = [:]
    }

    /// Skill text for the frontmost app, or for the site when a browser shows a URL.
    func skill(bundleID: String?, url: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        loadIndex()
        var keys: [String] = []
        if let host = url.flatMap(Self.host(of:)) { keys += Self.domainCandidates(host) }
        if let b = bundleID?.lowercased() { keys.append(b) }
        for k in keys {
            if let f = index[k] {
                if let c = cache[f] { return c }
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let body = String(Self.stripFrontmatter(text).prefix(Self.maxChars))
                cache[f] = body
                return body
            }
        }
        return nil
    }

    // MARK: Pure helpers

    static func matchKeys(in text: String) -> [String] {
        guard text.hasPrefix("---") else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l == "---" { break }
            if l.lowercased().hasPrefix("match:") {
                return l.dropFirst(6).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            }
        }
        return []
    }

    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let rest = text.dropFirst(3)
        guard let end = rest.range(of: "\n---") else { return text }
        return String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func host(of url: String) -> String? {
        let s = url.contains("://") ? url : "https://" + url
        return URLComponents(string: s)?.host?.lowercased()
    }

    /// "docs.google.com" → ["docs.google.com", "google.com"]; strips "www.".
    static func domainCandidates(_ host: String) -> [String] {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        var parts = h.split(separator: ".").map(String.init)
        var out: [String] = []
        while parts.count >= 2 {
            out.append(parts.joined(separator: "."))
            parts.removeFirst()
        }
        return out
    }
}
