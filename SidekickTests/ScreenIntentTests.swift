import XCTest
@testable import Sidekick

final class ScreenIntentTests: XCTestCase {
    func testScreenRequestsAreDetected() {
        for s in ["solve the first question on my screen and give me the whole detailed ans of it",
                  "what's this?", "explain this error", "summarize this page", "solve it", "Can you see my tab?",
                  "answer question number 3", "translate this paragraph", "what am I looking at"] {
            XCTAssertTrue(ScreenIntent.mentionsScreen(s), s)
        }
    }

    func testOrdinaryQuestionsDontCaptureTheScreen() {
        for s in ["what's the capital of france", "write me a poem about rain", "how do I learn swift quickly?",
                  "remind me what we talked about yesterday", "give me a recipe for pasta"] {
            XCTAssertFalse(ScreenIntent.mentionsScreen(s), s)
        }
    }
}
