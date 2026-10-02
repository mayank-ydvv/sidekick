import XCTest
@testable import Sidekick

final class ScheduleTests: XCTestCase {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }()
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testParseForms() {
        XCTAssertEqual(Schedule.parse("daily 21:00"), .daily(hour: 21, minute: 0))
        XCTAssertEqual(Schedule.parse("Daily 9pm"), .daily(hour: 21, minute: 0))
        XCTAssertEqual(Schedule.parse("weekdays 9:30am"), .weekdays([2, 3, 4, 5, 6], hour: 9, minute: 30))
        XCTAssertEqual(Schedule.parse("weekly mon 08:00"), .weekdays([2], hour: 8, minute: 0))
        XCTAssertEqual(Schedule.parse("friday 1800"), .weekdays([6], hour: 18, minute: 0))
        XCTAssertEqual(Schedule.parse("every 3 hours"), .interval(3 * 3600))
        XCTAssertEqual(Schedule.parse("every 2 minutes"), .interval(5 * 60))   // floor of 5 min
        XCTAssertEqual(Schedule.parse("0 21 * * 1-5"), .cron(minutes: [0], hours: [21], weekdays: [2, 3, 4, 5, 6]))
        XCTAssertNil(Schedule.parse("sometimes"))
        XCTAssertNil(Schedule.parse("daily 25:00"))
        XCTAssertNil(Schedule.parse("61 * * * *"))
    }

    func testNextDaily() {
        let now = date(2026, 10, 1, 20, 0)
        XCTAssertEqual(Schedule.daily(hour: 21, minute: 0).next(after: now, calendar: cal), date(2026, 10, 1, 21, 0))
        XCTAssertEqual(Schedule.daily(hour: 21, minute: 0).next(after: date(2026, 10, 1, 21, 0), calendar: cal), date(2026, 10, 2, 21, 0))
    }

    func testNextWeekdaysSkipsWeekend() {
        // 2026-10-02 is a Friday.
        let fri = date(2026, 10, 2, 10, 0)
        XCTAssertEqual(Schedule.parse("weekdays 09:00")?.next(after: fri, calendar: cal), date(2026, 10, 5, 9, 0))
    }

    func testNextCron() {
        let s = Schedule.parse("30 */6 * * *")!
        XCTAssertEqual(s.next(after: date(2026, 10, 1, 7, 0), calendar: cal), date(2026, 10, 1, 12, 30))
    }

    func testMinHeapOrder() {
        var h = MinHeap<Int>(<)
        for x in [5, 1, 9, 3, 7, 2, 8] { h.push(x) }
        XCTAssertEqual(h.peek, 1)
        var out: [Int] = []
        while let x = h.pop() { out.append(x) }
        XCTAssertEqual(out, [1, 2, 3, 5, 7, 8, 9])
        h.push(4); h.push(6); h.removeAll { $0 == 4 }
        XCTAssertEqual(h.pop(), 6)
    }
}

final class SkillsAndNotesTests: XCTestCase {
    func testSkillParse() {
        let s = Skill.parse("---\nname: Code reviewer\ndescription: Finds bugs\ntriggers: review, bug\n---\nList bugs first.", file: URL(fileURLWithPath: "/x/code-reviewer.md"))
        XCTAssertEqual(s.name, "Code reviewer")
        XCTAssertEqual(s.triggers, ["review", "bug"])
        XCTAssertEqual(s.body, "List bugs first.")
        XCTAssertTrue(s.matches("can you review this"))
        XCTAssertFalse(s.matches("what's the weather"))
        let always = Skill.parse("---\nname: A\ntriggers:\n---\nX", file: URL(fileURLWithPath: "/a.md"))
        XCTAssertTrue(always.matches("anything"))
    }

    func testComposeRespectsCap() {
        let skills = (0..<10).map { Skill(file: URL(fileURLWithPath: "/\($0).md"), name: "S\($0)", description: "", triggers: [], body: String(repeating: "x", count: 300)) }
        let text = SkillLibrary.compose(skills, cap: 1000)
        XCTAssertLessThanOrEqual(text.count, 1000)
        XCTAssertTrue(text.hasPrefix("## S0"))
    }

    @MainActor
    func testSkillLibraryInstallsAndToggles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = SkillLibrary(directory: dir)
        lib.save(name: "Pirate mode", description: "arr", triggers: "", body: "Talk like a pirate.")
        XCTAssertTrue(lib.skills.contains { $0.name == "Pirate mode" })
        XCTAssertTrue(lib.promptText(for: "hi").contains("Talk like a pirate."))
        lib.toggle(lib.skills.first { $0.name == "Pirate mode" }!)
        XCTAssertFalse(lib.promptText(for: "hi").contains("pirate"))
        try? FileManager.default.removeItem(at: dir)
    }

    func testAutoLink() {
        XCTAssertEqual(NotesWiki.autoLink("I use Figma with Notion daily", topics: ["Figma", "Notion"]),
                       "I use [[Figma]] with [[Notion]] daily")
        XCTAssertEqual(NotesWiki.autoLink("Figmatic is not Figma", topics: ["Figma"]), "Figmatic is not [[Figma]]")
        XCTAssertEqual(NotesWiki.autoLink("see [[Figma]] and Figma", topics: ["Figma"]), "see [[Figma]] and Figma")
    }

    @MainActor
    func testWikiSaveAppendAndSearch() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let w = NotesWiki(directory: dir)
        w.save(topic: "Swift", content: "Actors isolate state.")
        w.save(topic: "Concurrency", content: "Swift actors and tasks.")
        w.save(topic: "Swift", content: "Sendable matters.")
        XCTAssertEqual(w.topics, ["Concurrency", "Swift"])
        XCTAssertTrue(w.read("Concurrency").contains("[[Swift]] actors"))
        XCTAssertTrue(w.read("Swift").contains("Actors isolate state.") && w.read("Swift").contains("Sendable matters."))
        XCTAssertEqual(w.search("sendable"), ["Swift"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testBuddyNamesAndAvatars() {
        XCTAssertEqual(BuddyStore.cleanName("inbox  buddy!!"), "Inbox Buddy")
        XCTAssertEqual(BuddyStore.cleanName("day summarizer for evenings"), "Day Summarizer For")
        XCTAssertEqual(BuddyStore.cleanName("??"), "New Buddy")
        XCTAssertEqual(BuddyAvatar.preset(for: "Inbox Buddy"), BuddyAvatar.preset(for: "Inbox Buddy"))
        let (style, hue) = BuddyAvatar.parse(BuddyAvatar.preset(for: "X"))
        XCTAssertTrue(BuddyAvatar.styles.contains(style))
        XCTAssertTrue((0..<8).contains(hue))
    }
}

final class MCPTests: XCTestCase {
    func testParseToolsAndSanitize() throws {
        let result: [String: Any] = ["tools": [
            ["name": "create_issue", "description": "Create", "annotations": ["readOnlyHint": false],
             "inputSchema": ["type": "object", "$schema": "x", "additionalProperties": false,
                             "properties": ["title": ["type": "string", "default": "x"]]]],
            ["name": "list_issues", "annotations": ["readOnlyHint": true]],
        ]]
        let tools = MCPClient.parseTools(result)
        XCTAssertEqual(tools.map(\.name), ["create_issue", "list_issues"])
        XCTAssertEqual(tools.map(\.readOnly), [false, true])
        let schema = try JSONSerialization.jsonObject(with: tools[0].inputSchemaJSON) as! [String: Any]
        XCTAssertNil(schema["$schema"]); XCTAssertNil(schema["additionalProperties"])
        XCTAssertNil(((schema["properties"] as! [String: Any])["title"] as! [String: Any])["default"])
    }

    func testCallResultAndSSE() {
        let r = MCPClient.parseCallResult(["content": [["type": "text", "text": "ok"], ["type": "resource", "resource": ["uri": "file://a"]]], "isError": true])
        XCTAssertEqual(r.text, "ok\nfile://a")
        XCTAssertTrue(r.isError)
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"note\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"a\":1}}\n\n"
        XCTAssertEqual((MCPClient.lastSSEMessage(Data(sse.utf8))?["result"] as? [String: Any])?["a"] as? Int, 1)
    }

    func testToolNameAndEnv() {
        XCTAssertEqual(MCPClient.toolName(server: "Git Hub", tool: "create-issue"), "mcp_git_hub_create_issue")
        XCTAssertEqual(MCPManager.parseEnv("A=1\n B = two=2 \nbad"), ["A": "1", "B": "two=2"])
    }

    /// End-to-end over stdio against a tiny Python MCP server.
    func testStdioRoundTrip() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake_mcp_\(UUID().uuidString).py")
        try #"""
        import sys, json
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            meth = m["method"]
            if meth == "initialize": res = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "fake"}}
            elif meth == "tools/list": res = {"tools": [{"name": "echo", "description": "Echo", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}, "annotations": {"readOnlyHint": True}}]}
            elif meth == "tools/call": res = {"content": [{"type": "text", "text": "echo: " + m["params"]["arguments"]["text"]}]}
            else: res = {}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": res}) + "\n"); sys.stdout.flush()
        """#.write(to: script, atomically: true, encoding: .utf8)
        let client = MCPClient(config: MCPServerConfig(name: "fake", kind: .stdio, target: "/usr/bin/python3 -u '\(script.path)'"), env: [:])
        try await client.connect()
        let tools = await client.tools
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let r = try await client.call(tool: "echo", arguments: ["text": "hi"])
        XCTAssertEqual(r.text, "echo: hi")
        await client.disconnect()
        try? FileManager.default.removeItem(at: script)
    }
}
