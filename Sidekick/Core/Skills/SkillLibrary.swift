import Foundation
import Observation

struct Skill: Identifiable, Equatable {
    var id: String { file.lastPathComponent }
    var file: URL
    var name: String
    var description: String
    var triggers: [String]
    var body: String

    /// Frontmatter: name, description, triggers (comma list). Body = the instructions.
    static func parse(_ text: String, file: URL) -> Skill {
        var name = file.deletingPathExtension().lastPathComponent, desc = "", triggers: [String] = []
        var body = text
        if text.hasPrefix("---"), let end = text.dropFirst(3).range(of: "\n---") {
            let header = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound]
            for line in header.split(separator: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "name": name = kv[1]
                case "description": desc = kv[1]
                case "triggers": triggers = kv[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                default: break
                }
            }
            body = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Skill(file: file, name: name, description: desc, triggers: triggers, body: body)
    }

    func matches(_ text: String) -> Bool {
        triggers.isEmpty || triggers.contains { text.lowercased().contains($0) }
    }
}

/// Skills = markdown files in ~/Library/Application Support/Sidekick/Skills/. Enabled ones go into prompts.
@MainActor
@Observable
final class SkillLibrary {
    static let promptCap = 2000
    private(set) var skills: [Skill] = []
    var enabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabled), forKey: "skills.enabled") }
    }
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekick/Skills", isDirectory: true)
        enabled = Set(UserDefaults.standard.stringArray(forKey: "skills.enabled") ?? ["concise-answers.md"])
        installStarters()
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        skills = files.filter { $0.pathExtension == "md" }.compactMap { f in
            (try? String(contentsOf: f, encoding: .utf8)).map { Skill.parse($0, file: f) }
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Copies bundled starter skills once.
    private func installStarters() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !UserDefaults.standard.bool(forKey: "skills.installed"),
              let res = Bundle.main.resourceURL else { return }
        let starters = (try? fm.contentsOfDirectory(at: res, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("skill-") && $0.pathExtension == "md" } ?? []
        for s in starters {
            let dest = directory.appendingPathComponent(String(s.lastPathComponent.dropFirst("skill-".count)))
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: s, to: dest) }
        }
        UserDefaults.standard.set(true, forKey: "skills.installed")
    }

    func toggle(_ s: Skill) {
        if enabled.contains(s.id) { enabled.remove(s.id) } else { enabled.insert(s.id) }
    }

    /// Enabled skills relevant to `text`, capped for the prompt.
    func promptText(for text: String) -> String {
        Self.compose(skills.filter { enabled.contains($0.id) && $0.matches(text) }, cap: Self.promptCap)
    }

    nonisolated static func compose(_ skills: [Skill], cap: Int) -> String {
        var out = ""
        for s in skills {
            let block = "## \(s.name)\n\(s.body)\n"
            if out.count + block.count > cap { break }
            out += block
        }
        return out
    }

    func save(name: String, description: String, triggers: String, body: String, existing: Skill? = nil) {
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let file = existing?.file ?? directory.appendingPathComponent((slug.isEmpty ? "skill" : slug) + ".md")
        let text = "---\nname: \(name)\ndescription: \(description)\ntriggers: \(triggers)\n---\n\(body)\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
        enabled.insert(file.lastPathComponent)
        reload()
    }

    func delete(_ s: Skill) {
        try? FileManager.default.removeItem(at: s.file)
        enabled.remove(s.id)
        reload()
    }

    func importFile(_ url: URL) {
        let dest = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        reload()
    }
}
