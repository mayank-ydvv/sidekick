import XCTest
@testable import Sidekick

final class MemoryDiffTests: XCTestCase {
    func testParseAndApply() {
        let diff = MemoryDiff.parse("""
        + profile: Name is Mayank
        + profile: Prefers short answers
        + volatile: Building the Sidekick app
        - profile: Likes long answers
        ~ profile: Lives in Pune => Lives in Bengaluru
        nonsense line
        + other: ignored
        """)
        XCTAssertEqual(diff.profile.count, 4)
        XCTAssertEqual(diff.volatile, [.add("Building the Sidekick app")])

        let before = "- Likes long answers\n- Lives in Pune"
        let after = MemoryDiff.apply(diff.profile, to: before, stampDate: nil)
        XCTAssertEqual(after, "- Lives in Bengaluru\n- Name is Mayank\n- Prefers short answers")
    }

    func testDuplicatesIgnoredCaseInsensitive() {
        let out = MemoryDiff.apply([.add("prefers short answers")], to: "- Prefers short answers", stampDate: nil)
        XCTAssertEqual(out, "- Prefers short answers")
    }

    func testVolatileStampAndExpiry() {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        let text = MemoryDiff.apply([.add("Fixing the notch")], to: "", stampDate: d)
        XCTAssertTrue(text.hasPrefix("- [\(MemoryDiff.dayString(d))] Fixing the notch"))
        XCTAssertEqual(MemoryDiff.expire(text, olderThanDays: 7, now: d.addingTimeInterval(3 * 86_400)), text)
        XCTAssertEqual(MemoryDiff.expire(text, olderThanDays: 7, now: d.addingTimeInterval(9 * 86_400)), "")
        // Removing matches regardless of the date stamp.
        XCTAssertEqual(MemoryDiff.apply([.remove("fixing the notch")], to: text, stampDate: d), "")
    }

    func testSecretsAreNeverStored() {
        let diff = MemoryDiff.parse("""
        + profile: Card number is 4111 1111 1111 1111
        + profile: Wifi password is hunter2
        + profile: API key AIzaSyA1234567890abcdefghij
        + profile: OTP code 482913
        + profile: Works as a designer
        """)
        XCTAssertEqual(diff.profile, [.add("Works as a designer")])
    }

    func testUrgentPhrases() {
        XCTAssertTrue(MemoryUpdater.isUrgent("my name is Mayank, keep answers short"))
        XCTAssertTrue(MemoryUpdater.isUrgent("Remember that I use Figma"))
        XCTAssertFalse(MemoryUpdater.isUrgent("what's on my screen?"))
    }

    @MainActor
    func testStoreRoundTripAndUserName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = MemoryStore(directory: dir)
        m.apply(MemoryDiff.parse("+ profile: Name is Mayank\n+ volatile: Shipping phase 5"))
        let reloaded = MemoryStore(directory: dir)
        XCTAssertTrue(reloaded.profile.contains("Name is Mayank"))
        XCTAssertTrue(reloaded.volatile.contains("Shipping phase 5"))
        XCTAssertEqual(reloaded.userName, "Mayank")
        reloaded.deleteAll()
        XCTAssertEqual(MemoryStore(directory: dir).profile, "")
        try? FileManager.default.removeItem(at: dir)
    }
}

final class MarkdownTests: XCTestCase {
    let doc = """
    # Title
    Some **bold** text
    continues here.

    - one
    - two
      wrapped
    1. first
    2. second

    > quoted

    ```swift
    let x = 1 // hi
    ```

    | a | b |
    |---|:-:|
    | 1 | 2 |

    ---
    """

    func testParse() {
        let b = Markdown.parse(doc)
        XCTAssertEqual(b, [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\ncontinues here."),
            .bullet(items: ["one", "two wrapped"]),
            .numbered(start: 1, items: ["first", "second"]),
            .quote("quoted"),
            .code(language: "swift", code: "let x = 1 // hi", closed: true),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .rule,
        ])
    }

    func testUnclosedCodeFence() {
        XCTAssertEqual(Markdown.parse("```py\nprint(1)"), [.code(language: "py", code: "print(1)", closed: false)])
    }

    func testIncrementalMatchesFullParseForAnyChunking() {
        for size in [1, 2, 3, 7, 13, 50] {
            var inc = IncrementalMarkdown()
            var i = doc.startIndex
            while i < doc.endIndex {
                let e = doc.index(i, offsetBy: size, limitedBy: doc.endIndex) ?? doc.endIndex
                inc.append(String(doc[i..<e]))
                i = e
            }
            XCTAssertEqual(inc.blocks, Markdown.parse(doc), "chunk size \(size)")
        }
    }

    func testIncrementalFreezesCompletedBlocks() {
        var inc = IncrementalMarkdown()
        inc.append("para one\n\npara two")
        XCTAssertEqual(inc.stable, [.paragraph("para one")])
        XCTAssertEqual(inc.tail, "para two")
        // A blank line inside a code fence is not a boundary.
        var c = IncrementalMarkdown()
        c.append("```\na\n\nb")
        XCTAssertTrue(c.stable.isEmpty)
    }

    func testHighlighter() {
        let code = #"let s = "hi" // note"#
        let kinds = SyntaxHighlighter.spans(code, language: "swift").map(\.1)
        XCTAssertEqual(kinds, [.keyword, .string, .comment])
        // '#' is a comment only in hash-comment languages.
        XCTAssertEqual(SyntaxHighlighter.spans("# x", language: "python").map(\.1), [.comment])
        XCTAssertFalse(SyntaxHighlighter.spans("#include", language: "c").contains { $0.1 == .comment })
    }
}

final class NotchAndChatTests: XCTestCase {
    func testNotchFromAuxiliaryAreas() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let g = NotchGeometry.forScreen(frame: frame,
                                        auxLeft: CGRect(x: 0, y: 950, width: 660, height: 32),
                                        auxRight: CGRect(x: 852, y: 950, width: 660, height: 32), safeTop: 32)
        XCTAssertFalse(g.isVirtual)
        XCTAssertEqual(g.rect, CGRect(x: 660, y: 950, width: 192, height: 32))
        XCTAssertTrue(g.isHotspot(CGPoint(x: 650, y: 980), screenTop: 982))   // within ±20 pt
        XCTAssertFalse(g.isHotspot(CGPoint(x: 600, y: 980), screenTop: 982))
        XCTAssertFalse(g.isHotspot(CGPoint(x: 700, y: 960), screenTop: 982))  // below the 6 pt band
    }

    func testVirtualNotchOnExternalDisplay() {
        let g = NotchGeometry.forScreen(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), auxLeft: nil, auxRight: nil, safeTop: 0)
        XCTAssertTrue(g.isVirtual)
        XCTAssertEqual(g.rect, CGRect(x: 1512 + 960 - 90, y: 1048, width: 180, height: 32))
    }

    func testChatSections() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        XCTAssertEqual(ChatSection.of(now.addingTimeInterval(-3600), now: now, calendar: cal), .today)
        XCTAssertEqual(ChatSection.of(now.addingTimeInterval(-86_400), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(ChatSection.of(now.addingTimeInterval(-4 * 86_400), now: now, calendar: cal), .week)
        XCTAssertEqual(ChatSection.of(now.addingTimeInterval(-30 * 86_400), now: now, calendar: cal), .older)
    }
}

final class DatabaseTests: XCTestCase {
    func testConversationsMessagesAndFTS() async throws {
        let db = try AppDatabase.inMemory()
        let c1 = try await db.createConversation(title: "swift help")
        let c2 = try await db.createConversation(title: "dinner")
        _ = try await db.addMessage(MessageRecord(conversationId: c1.id!, role: "user", text: "How do actors work in Swift concurrency?"))
        _ = try await db.addMessage(MessageRecord(conversationId: c2.id!, role: "user", text: "Suggest a paneer recipe"))
        let hits = try await db.searchConversationIds("concur")      // prefix match
        XCTAssertEqual(hits, [c1.id!])
        let paneer = try await db.searchConversationIds("paneer recipe")
        XCTAssertEqual(paneer, [c2.id!])
        let none = try await db.searchConversationIds("nothing here")
        XCTAssertEqual(none, [])
        let msgs = try await db.messages(conversationId: c1.id!)
        XCTAssertEqual(msgs.count, 1)

        try await db.deleteConversation(c1.id!)
        let after = try await db.messages(conversationId: c1.id!)
        XCTAssertEqual(after.count, 0)     // cascade
        let gone = try await db.searchConversationIds("actors")
        XCTAssertEqual(gone, [])            // FTS stays in sync
    }

    func testUsageUpsert() async throws {
        let db = try AppDatabase.inMemory()
        try await db.recordUsage(date: "2026-10-01", model: "m", usage: TokenUsage(inputTokens: 100, outputTokens: 10), cost: 0.5)
        try await db.recordUsage(date: "2026-10-01", model: "m", usage: TokenUsage(inputTokens: 50, outputTokens: 5), cost: 0.25)
        let rows = try await db.usage(since: "2026-10-01")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inputTokens, 150)
        XCTAssertEqual(rows[0].costUSD, 0.75, accuracy: 1e-9)
    }

    func testDictionaryTable() async throws {
        let db = try AppDatabase.inMemory()
        try await db.upsertDictionary(DictionaryRecord(id: nil, wrong: "Clode", right: "Claude", hits: 1, updatedAt: Date()))
        try await db.upsertDictionary(DictionaryRecord(id: nil, wrong: "clode", right: "Claude", hits: 3, updatedAt: Date()))
        let rows = try db.dictionaryEntries()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].hits, 3)
    }

    func testVolatileFactsAreStampedOnce() {
        let d = ISO8601DateFormatter().date(from: "2026-10-02T09:00:00Z")!
        let out = MemoryDiff.apply([.add("[2026-10-01] Working on a C++ problem."), .add("- [2026-09-30] [2026-09-29] Reading docs.")],
                                   to: "", stampDate: d)
        XCTAssertFalse(out.contains("2026-10-01"), out)
        XCTAssertFalse(out.contains("2026-09-29"), out)
        XCTAssertTrue(out.contains("] Working on a C++ problem."), out)
        XCTAssertTrue(out.contains("] Reading docs."), out)
    }

    func testProfileFactsGoIntoSections() {
        let diff = MemoryDiff.parse("""
        + profile/preferences: Prefers step-by-step math answers
        + profile/work: Building Sidekick, a macOS assistant
        + profile: Name is Mayank
        + profile (people): Rahul is a close friend
        + volatile: Working on a C++ problem
        """)
        let out = MemoryDiff.applySectioned(diff.profile, to: "")
        XCTAssertEqual(out, """
        ## About me
        - Name is Mayank

        ## Work & projects
        - Building Sidekick, a macOS assistant

        ## Preferences
        - Prefers step-by-step math answers

        ## People
        - Rahul is a close friend
        """)
        XCTAssertEqual(diff.volatile, [.add("Working on a C++ problem")])
    }

    func testSectionedEditsAndOldFlatFiles() {
        let old = "- Name is Mayank\n- Prefers short answers"
        var out = MemoryDiff.applySectioned([.replace("Prefers short answers", "Prefers detailed answers"),
                                             .add("Likes lofi music", section: "interests"),
                                             .add("name is mayank", section: "about")], to: old)
        XCTAssertEqual(out, "## About me\n- Name is Mayank\n- Prefers detailed answers\n\n## Interests & habits\n- Likes lofi music")
        out = MemoryDiff.applySectioned([.remove("Likes lofi music")], to: out)
        XCTAssertFalse(out.contains("Interests"), out)
    }
}
