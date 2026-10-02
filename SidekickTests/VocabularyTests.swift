import XCTest
@testable import Sidekick

final class VocabularyTests: XCTestCase {
    func testNamesFromScreenText() {
        let lines = ["WhatsApp  File  Edit  View  Window  Help", "Chats 87", "Search", "Mayank Yadav (You)  2:05 PM",
                     "Ravi Sharma  2:00 PM", "Priya Mehta, Ravi Sharma 21/05/26", "UNREAD", "Meta AI"]
        let names = Vocabulary.names(in: lines)
        XCTAssertEqual(names.first, "Ravi Sharma")                  // seen twice → first
        XCTAssertTrue(names.contains("Mayank Yadav"))
        XCTAssertTrue(names.contains("Priya Mehta"))
        XCTAssertTrue(names.contains("WhatsApp"))
        XCTAssertFalse(names.contains("File"))
        XCTAssertFalse(names.contains(where: { $0.contains("UNREAD") || $0 == "Search" || $0 == "Chats" }))
    }

    func testPromptIsShortAndDeduplicated() {
        let p = Vocabulary.prompt(screen: ["Ravi Sharma", "WhatsApp", "ravi sharma"], memory: ["Rahul"], dictionary: ["Claude"])!
        XCTAssertEqual(p, "Sidekick, Claude, Rahul, Ravi Sharma, WhatsApp.")
        XCTAssertNil(Vocabulary.prompt(screen: [], memory: [], dictionary: []))
        let long = Vocabulary.prompt(screen: (0..<200).map { "Name\($0) Person" }, memory: [], dictionary: [])!
        XCTAssertLessThanOrEqual(long.count, 302)
    }

    func testDetectsWhisperRepeatingTheHints() {
        let hint = "Sidekick, Ravi Sharma, Priya Mehta, WhatsApp, Meta AI."
        XCTAssertTrue(TalkCoordinator.echoesPrompt("Sidekick, Ravi Sharma, Priya Mehta, WhatsApp.", hint))
        XCTAssertFalse(TalkCoordinator.echoesPrompt("Open WhatsApp, search for Ravi Sharma and send him hey.", hint))
    }
}
