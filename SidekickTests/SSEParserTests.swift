import XCTest
@testable import Sidekick

final class SSEParserTests: XCTestCase {
    func testParsesTextChunk() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line)?.text, "Hello")
    }

    func testSkipsThoughtParts() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"hmm","thought":true},{"text":"Hi"}]}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line)?.text, "Hi")
    }

    func testParsesUsageAndFinish() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"."}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1200,"candidatesTokenCount":30,"thoughtsTokenCount":5}}"#
        let c = SSEParser.parse(line: line)
        XCTAssertEqual(c?.usage, TokenUsage(inputTokens: 1200, outputTokens: 35))
        XCTAssertEqual(c?.finishReason, "STOP")
    }

    func testIgnoresNonDataAndMalformed() {
        XCTAssertNil(SSEParser.parse(line: ""))
        XCTAssertNil(SSEParser.parse(line: ": keep-alive"))
        XCTAssertNil(SSEParser.parse(line: "data: {not json"))
        XCTAssertNil(SSEParser.parse(line: "data: [DONE]"))
    }

    func testRequestBodyShape() throws {
        let r = GeminiRequest(model: "m", system: "sys",
                              turns: [GeminiTurn(role: .user, text: "q", jpeg: Data([1, 2, 3]))],
                              thinkingLevel: "low")
        let req = try GeminiClient.makeURLRequest(r, key: "k", includeThinking: true)
        XCTAssertEqual(req.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/m:streamGenerateContent?alt=sse")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "k")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let contents = json["contents"] as! [[String: Any]]
        let parts = contents[0]["parts"] as! [[String: Any]]
        XCTAssertEqual((parts[0]["inlineData"] as? [String: Any])?["data"] as? String, "AQID")
        XCTAssertEqual(parts[1]["text"] as? String, "q")
        let gen = json["generationConfig"] as! [String: Any]
        XCTAssertEqual((gen["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "low")

        let noThink = GeminiClient.body(r, includeThinking: false)
        XCTAssertNil((noThink["generationConfig"] as! [String: Any])["thinkingConfig"])
    }

    func testPromptTurnsOnlyLatestHasScreenshot() {
        let history = (0..<15).map { ConversationTurn(user: "u\($0)", assistant: "a\($0)") }
        let turns = PromptBuilder.turns(history: history, userText: "now", screenshot: Data([9]))
        XCTAssertEqual(turns.count, 21)
        XCTAssertEqual(turns.first?.text, "u5")
        XCTAssertEqual(turns.filter { $0.jpeg != nil }.count, 1)
        XCTAssertNotNil(turns.last?.jpeg)
    }

    func testSystemPromptFillsPlaceholders() {
        let s = PromptBuilder.system(template: "{PROFILE}|{APP}|{TITLE}|{URL}|{APP_SKILL for current app}",
                                     context: .init(appName: "Finder", windowTitle: nil, url: nil))
        XCTAssertEqual(s, "User profile: (none)|Finder|unknown|none|")
    }
}
