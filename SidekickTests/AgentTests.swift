import XCTest
@testable import Sidekick

final class AgentToolTests: XCTestCase {
    var tmp: URL!
    var ctx: ToolContext!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let out = tmp.appendingPathComponent("out"), extra = tmp.appendingPathComponent("approved")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        ctx = ToolContext(outputFolder: out, allowedFolders: [extra], gemini: GeminiClient(apiKey: { nil }), searchModel: "x")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testPathScoping() {
        XCTAssertNotNil(FileTools.resolve("report.csv", ctx: ctx))
        XCTAssertNotNil(FileTools.resolve(tmp.appendingPathComponent("approved/a.txt").path, ctx: ctx))
        XCTAssertNil(FileTools.resolve("../escape.txt", ctx: ctx))
        XCTAssertNil(FileTools.resolve("/etc/passwd", ctx: ctx))
        XCTAssertNil(FileTools.resolve(tmp.appendingPathComponent("approved-not/a.txt").path, ctx: ctx))   // prefix trick
    }

    func testCSVEscaping() {
        let s = FileTools.csv(header: ["Company", "Revenue"], rows: [["Tata, Consultancy", "29.1"], ["Say \"hi\"", "1"]])
        XCTAssertEqual(s, "Company,Revenue\r\n\"Tata, Consultancy\",29.1\r\n\"Say \"\"hi\"\"\",1\r\n")
    }

    func testCreateCSVToolWritesUniqueFiles() async throws {
        let args: [String: Any] = ["filename": "top it", "header": ["a", "b"], "rows": [["1", "2"], ["3", "4"]]]
        let r1 = try await FileTools.createCSV.run(args, ctx)
        let r2 = try await FileTools.createCSV.run(args, ctx)
        XCTAssertEqual(r1.files.first?.lastPathComponent, "top it.csv")
        XCTAssertEqual(r2.files.first?.lastPathComponent, "top it 2.csv")
        XCTAssertEqual(try String(contentsOf: r1.files[0], encoding: .utf8), "a,b\r\n1,2\r\n3,4\r\n")
    }

    func testOverwriteNeedsConfirmation() async throws {
        let args: [String: Any] = ["path": "notes.txt", "content": "hi"]
        XCTAssertFalse(FileTools.write.requiresConfirmation(args, ctx))
        _ = try await FileTools.write.run(args, ctx)
        XCTAssertTrue(FileTools.write.requiresConfirmation(args, ctx))
        XCTAssertTrue(ShellTool.tool.requiresConfirmation(["command": "ls"], ctx))
    }

    func testXLSXIsAValidZipWithSheet() async throws {
        let r = try await FileTools.createXLSX.run(["filename": "t", "header": ["Name", "Value"], "rows": [["A & B", "1,200"], ["C", "x"]]], ctx)
        let url = try XCTUnwrap(r.files.first)
        XCTAssertEqual(url.pathExtension, "xlsx")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(xml.contains("<t>A &amp; B</t>"))
        XCTAssertTrue(xml.contains("<c r=\"B2\"><v>1200</v></c>"))       // numbers stay numbers
        XCTAssertTrue(xml.contains("<c r=\"B3\" t=\"inlineStr\"><is><t>x</t></is></c>"))
    }

    func testSafeName() {
        XCTAssertEqual(FileTools.safeName("a/b:c", ext: "csv"), "a-b-c.csv")
        XCTAssertEqual(FileTools.safeName("x.CSV", ext: "csv"), "x.CSV")
        XCTAssertEqual(FileTools.safeName("  ", ext: "md"), "output.md")
    }

    func testHTMLToText() {
        let html = "<html><head><style>.a{}</style><script>var x=1</script></head><body><nav>menu</nav><h1>Title</h1><p>Hello&nbsp;<b>world</b> &amp; friends</p><ul><li>one</li><li>two</li></ul></body></html>"
        XCTAssertEqual(WebTools.htmlToText(html), "Title\nHello world & friends\n• one\n• two")
    }

    func testParseGroundedSources() {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"TCS is largest."}]},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://a.com","title":"A"}}]}}]}"#
        XCTAssertEqual(WebTools.parseGrounded(Data(json.utf8)), "TCS is largest.\n\nSources:\n- A: https://a.com")
    }

    func testParseFunctionCallsKeepsRawContent() {
        let json = #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"web_search","args":{"query":"top IT"}},"thoughtSignature":"abc"},{"text":"working"}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5}}"#
        let p = AgentRunner.parse(Data(json.utf8))
        XCTAssertEqual(p.calls.map(\.name), ["web_search"])
        XCTAssertEqual(p.calls.first?.args["query"] as? String, "top IT")
        XCTAssertEqual(p.text, "working")
        XCTAssertEqual(p.usage, TokenUsage(inputTokens: 10, outputTokens: 5))
        let parts = p.content?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["thoughtSignature"] as? String, "abc")   // echoed back verbatim
    }

    func testFinalAnswerHasNoCalls() {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Saved top-it.csv."}]}}]}"#
        let p = AgentRunner.parse(Data(json.utf8))
        XCTAssertTrue(p.calls.isEmpty)
        XCTAssertEqual(p.content?["role"] as? String, "model")
    }

    func testTimeout() async {
        do {
            _ = try await withTimeout(0.05) { try await Task.sleep(nanoseconds: 2_000_000_000); return 1 }
            XCTFail("should time out")
        } catch { XCTAssertTrue(error is TimeoutError) }
        let v = try? await withTimeout(1) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testRegistryDeclarationsAreJSONSerializable() throws {
        let decl = ToolRegistry.declarations(ToolRegistry.all())
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: decl))
        let names = (decl[0]["functionDeclarations"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(Set(names).count, names.count)
        for n in ["open_app", "open_url", "web_search", "fetch_url", "files_read", "files_write", "files_list",
                  "create_csv", "create_xlsx", "create_markdown", "run_shell", "notes_create", "calendar_create_event", "reminders_create"] {
            XCTAssertTrue(names.contains(n), n)
        }
    }
}
