import Foundation
import GRDB
import Observation

/// Persistent named buddies, each with a role, folder (~/Sidekick/Buddies/<name>/), MEMORY.md and conversation.
@MainActor
@Observable
final class BuddyStore {
    private(set) var buddies: [BuddyRecord] = []
    private(set) var routines: [RoutineRecord] = []
    private let db: AppDatabase
    private var observers: [AnyDatabaseCancellable] = []

    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sidekick/Buddies", isDirectory: true)
    static let maxPerRequest = 5

    init(db: AppDatabase) {
        self.db = db
        observers.append(ValueObservation.tracking { try BuddyRecord.order(Column("createdAt")).fetchAll($0) }
            .start(in: db.writer, scheduling: .immediate, onError: { _ in }, onChange: { [weak self] in self?.buddies = $0 }))
        observers.append(ValueObservation.tracking { try RoutineRecord.order(Column("id")).fetchAll($0) }
            .start(in: db.writer, scheduling: .immediate, onError: { _ in }, onChange: { [weak self] in self?.routines = $0 }))
        ensureDefaults()
    }

    var active: [BuddyRecord] { buddies.filter { !$0.archived } }

    func buddy(_ id: Int64?) -> BuddyRecord? { buddies.first { $0.id == id } }
    func buddy(named n: String) -> BuddyRecord? { buddies.first { $0.name.lowercased() == n.lowercased() } }
    func routines(for b: BuddyRecord) -> [RoutineRecord] { routines.filter { $0.buddyId == b.id } }

    private func ensureDefaults() {
        guard !UserDefaults.standard.bool(forKey: "buddies.defaults") else { return }
        UserDefaults.standard.set(true, forKey: "buddies.defaults")
        Task {
            _ = try? await create(name: "General Helper", role: "A capable all-round assistant who gets everyday tasks done.", avatar: "blob:0")
            _ = try? await create(name: "Tutor", role: "A patient teacher who explains things step by step and checks understanding.", avatar: "pebble:2")
        }
    }

    /// Two friendly words, title-cased, filesystem-safe.
    nonisolated static func cleanName(_ s: String) -> String {
        let words = s.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .split(separator: " ").prefix(3).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return words.isEmpty ? "New Buddy" : words.joined(separator: " ")
    }

    nonisolated static func folder(for name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    @discardableResult
    func create(name raw: String, role: String, avatar: String? = nil) async throws -> BuddyRecord {
        let base = Self.cleanName(raw)
        let name = buddy(named: base) != nil ? base + " 2" : base
        let folder = Self.folder(for: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memFile = folder.appendingPathComponent("MEMORY.md")
        if !FileManager.default.fileExists(atPath: memFile.path) {
            try "# \(name)\nRole: \(role)\n".write(to: memFile, atomically: true, encoding: .utf8)
        }
        let av = avatar ?? BuddyAvatar.preset(for: name)
        let rec = try await db.writer.write { db -> BuddyRecord in
            var b = BuddyRecord(name: name, avatar: av, rolePrompt: role, folderPath: folder.path)
            try b.insert(db)
            var c = ConversationRecord(buddyId: b.id, title: name.lowercased(), kind: "buddy")
            try c.insert(db)
            return b
        }
        return rec
    }

    func setArchived(_ b: BuddyRecord, _ v: Bool) {
        var b = b
        b.archived = v
        Task { [db, b] in _ = try? await db.writer.write { try b.update($0) } }
    }

    func update(_ b: BuddyRecord) {
        Task { [db, b] in _ = try? await db.writer.write { try b.update($0) } }
    }

    func conversationId(for b: BuddyRecord) async -> Int64? {
        guard let bid = b.id else { return nil }
        return try? await db.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM conversation WHERE buddyId = ? ORDER BY id LIMIT 1", arguments: [bid])
        }
    }

    func memory(of b: BuddyRecord) -> String {
        (try? String(contentsOf: URL(fileURLWithPath: b.folderPath).appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
    }

    /// Keeps the last 40 dated lines of what the buddy did.
    func remember(_ b: BuddyRecord, _ line: String) {
        let url = URL(fileURLWithPath: b.folderPath).appendingPathComponent("MEMORY.md")
        var lines = memory(of: b).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.append("- [\(MemoryDiff.dayString(Date()))] \(line.prefix(200))")
        let header = lines.prefix(2)
        let body = lines.dropFirst(2).suffix(40)
        try? (Array(header) + body).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Newest files in the buddy's folder (Peek shows 3).
    func newestFiles(_ b: BuddyRecord, limit: Int = 3) -> [URL] {
        let dir = URL(fileURLWithPath: b.folderPath)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent != "MEMORY.md" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .prefix(limit).map { $0 }
    }

    // MARK: Routines

    @discardableResult
    func addRoutine(buddy b: BuddyRecord, prompt: String, schedule: String) async throws -> RoutineRecord {
        guard let bid = b.id else { throw CocoaError(.validationMissingMandatoryProperty) }
        guard let spec = Schedule.parse(schedule) else { throw ScheduleError.invalid(schedule) }
        let next = spec.next(after: Date())
        return try await db.writer.write { db -> RoutineRecord in
            var r = RoutineRecord(buddyId: bid, prompt: prompt, schedule: schedule, nextRunAt: next)
            try r.insert(db)
            return r
        }
    }

    func saveRoutine(_ r: RoutineRecord) async {
        _ = try? await db.writer.write { try r.update($0) }
    }

    func deleteRoutine(_ r: RoutineRecord) {
        Task { [db, r] in _ = try? await db.writer.write { try r.delete($0) } }
    }

    enum ScheduleError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let s) = self { return "i couldn't understand the schedule \"\(s)\" — try \"daily 21:00\" or \"weekdays 9am\"" }
            return nil
        }
    }
}

/// Original avatar presets: a shape style + hue, derived from the name.
enum BuddyAvatar {
    static let styles = ["blob", "pebble", "drop", "star", "cloud"]

    static func preset(for name: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(styles[Int(h % UInt64(styles.count))]):\(Int((h >> 8) % 8))"
    }

    static func parse(_ s: String) -> (style: String, hue: Int) {
        let p = s.split(separator: ":")
        return (p.first.map(String.init) ?? "blob", p.count > 1 ? Int(p[1]) ?? 0 : 0)
    }
}
