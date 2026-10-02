import Foundation
import GRDB

// MARK: Records (spec §6)

struct BuddyRecord: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "buddy"
    var id: Int64?
    var name: String
    var avatar: String
    var rolePrompt: String
    var folderPath: String
    var archived = false
    var createdAt = Date()
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ConversationRecord: Codable, Equatable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "conversation"
    var id: Int64?
    var buddyId: Int64?
    var title: String
    var archived = false
    var updatedAt = Date()
    /// "chat" (typed in Home) or "voice" (push-to-talk turns).
    var kind = "chat"
    var unread = false
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct MessageRecord: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "message"
    var id: Int64?
    var conversationId: Int64
    var role: String          // "user" | "assistant"
    var text: String
    var model: String?
    var inputTokens = 0
    var outputTokens = 0
    var costUSD = 0.0
    var createdAt = Date()
    var feedback: Int?        // 1 = thumbs up, -1 = thumbs down
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct RoutineRecord: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "routine"
    var id: Int64?
    var buddyId: Int64
    var prompt: String
    var schedule: String
    var nextRunAt: Date?
    var failCount = 0
    var enabled = true
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct AgentRunRecord: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "agent_run"
    var id: Int64?
    var conversationId: Int64?
    var task: String
    var status: String
    var steps: String = "[]"      // JSON
    var filesJSON: String = "[]"  // JSON
    var startedAt = Date()
    var endedAt: Date?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct DictionaryRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dictionary"
    var id: Int64?
    var wrong: String
    var right: String
    var hits: Int
    var updatedAt: Date
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct UsageDailyRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usage_daily"
    var date: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
}

// MARK: Database

/// One SQLite file at ~/Library/Application Support/Sidekick/sidekick.sqlite.
/// All writes go through GRDB's serialized writer, off the main thread.
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static func openDefault() throws -> AppDatabase {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekick", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        let pool = try DatabasePool(path: dir.appendingPathComponent("sidekick.sqlite").path, configuration: config)
        return try AppDatabase(pool)
    }

    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "buddy") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("avatar", .text).notNull()
                t.column("rolePrompt", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "conversation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("buddyId", .integer).references("buddy", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull().indexed()
                t.column("kind", .text).notNull().defaults(to: "chat")
                t.column("unread", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .integer).notNull().indexed()
                    .references("conversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("model", .text)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("feedback", .integer)
            }
            // Full-text search over message text, kept in sync by triggers.
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61()
                t.column("text")
            }
            try db.create(table: "routine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("buddyId", .integer).notNull().references("buddy", onDelete: .cascade)
                t.column("prompt", .text).notNull()
                t.column("schedule", .text).notNull()
                t.column("nextRunAt", .datetime)
                t.column("failCount", .integer).notNull().defaults(to: 0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "agent_run") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .integer).references("conversation", onDelete: .setNull)
                t.column("task", .text).notNull()
                t.column("status", .text).notNull()
                t.column("steps", .text).notNull()
                t.column("filesJSON", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
            try db.create(table: "dictionary") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("wrong", .text).notNull().unique(onConflict: .replace)
                t.column("right", .text).notNull()
                t.column("hits", .integer).notNull().defaults(to: 1)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "usage_daily") { t in
                t.column("date", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.primaryKey(["date", "model"])
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("valueJSON", .text).notNull()
            }
        }
        return m
    }
}

// MARK: Queries

extension AppDatabase {
    func createConversation(title: String, kind: String = "chat", buddyId: Int64? = nil) async throws -> ConversationRecord {
        try await writer.write { db in
            var c = ConversationRecord(id: nil, buddyId: buddyId, title: title, kind: kind)
            try c.insert(db)
            return c
        }
    }

    @discardableResult
    func addMessage(_ m: MessageRecord) async throws -> MessageRecord {
        try await writer.write { db in
            var m = m
            try m.insert(db)
            try db.execute(sql: "UPDATE conversation SET updatedAt = ? WHERE id = ?", arguments: [m.createdAt, m.conversationId])
            return m
        }
    }

    func updateMessage(_ m: MessageRecord) async throws {
        try await writer.write { db in try m.update(db) }
    }

    func deleteMessages(conversationId: Int64, fromId: Int64) async throws {
        _ = try await writer.write { db in
            try MessageRecord.filter(Column("conversationId") == conversationId && Column("id") >= fromId).deleteAll(db)
        }
    }

    func rename(_ id: Int64, title: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE conversation SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    func setArchived(_ id: Int64, _ archived: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE conversation SET archived = ? WHERE id = ?", arguments: [archived, id])
        }
    }

    func setUnread(_ id: Int64, _ unread: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE conversation SET unread = ? WHERE id = ?", arguments: [unread, id])
        }
    }

    func deleteConversation(_ id: Int64) async throws {
        _ = try await writer.write { db in try ConversationRecord.deleteOne(db, key: id) }
    }

    func messages(conversationId: Int64) async throws -> [MessageRecord] {
        try await writer.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId).order(Column("id")).fetchAll(db)
        }
    }

    /// Conversation ids whose messages match `query` (prefix match on every word), via FTS5.
    func searchConversationIds(_ query: String) async throws -> [Int64] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try await writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT message.conversationId FROM message
                JOIN message_fts ON message_fts.rowid = message.id
                WHERE message_fts MATCH ?
                ORDER BY message.id DESC LIMIT 200
                """, arguments: [pattern])
        }
    }

    // Usage (replaces the Phase 1 UserDefaults store)
    func recordUsage(date: String, model: String, usage: TokenUsage, cost: Double) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO usage_daily (date, model, inputTokens, outputTokens, costUSD) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(date, model) DO UPDATE SET
                  inputTokens = inputTokens + excluded.inputTokens,
                  outputTokens = outputTokens + excluded.outputTokens,
                  costUSD = costUSD + excluded.costUSD
                """, arguments: [date, model, usage.inputTokens, usage.outputTokens, cost])
        }
    }

    func usage(since date: String) async throws -> [UsageDailyRecord] {
        try await writer.read { db in
            try UsageDailyRecord.filter(Column("date") >= date).order(Column("date")).fetchAll(db)
        }
    }

    // Dictionary
    func dictionaryEntries() throws -> [DictionaryRecord] {
        try writer.read { db in try DictionaryRecord.order(Column("hits").desc).fetchAll(db) }
    }

    func upsertDictionary(_ e: DictionaryRecord) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO dictionary (wrong, right, hits, updatedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(wrong) DO UPDATE SET right = excluded.right, hits = excluded.hits, updatedAt = excluded.updatedAt
                """, arguments: [e.wrong.lowercased(), e.right, e.hits, e.updatedAt])
        }
    }

    func deleteDictionary(wrong: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM dictionary WHERE wrong = ?", arguments: [wrong.lowercased()])
        }
    }

    /// "Delete all data": every table emptied.
    func wipe() async throws {
        try await writer.write { db in
            for t in ["message", "agent_run", "routine", "conversation", "buddy", "dictionary", "usage_daily", "setting"] {
                try db.execute(sql: "DELETE FROM \(t)")
            }
        }
    }
}
