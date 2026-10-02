import XCTest
@testable import Sidekick

final class LanguageLineTests: XCTestCase {
    func testEnglishQuestionsAskForEnglish() {
        for q in ["what's on my screen right now?", "can you help me with java code", "solve the first question on my screen"] {
            XCTAssertTrue(PromptBuilder.languageLine(for: q).contains("reply in English only"), q)
        }
    }

    func testHinglishAndHindiKeepTheirLanguage() {
        XCTAssertTrue(PromptBuilder.languageLine(for: "mujhe java mein ek loop likhna hai, help karo").contains("Hinglish"))
        XCTAssertTrue(PromptBuilder.languageLine(for: "मेरी स्क्रीन पर क्या है?").contains("Hindi"))
    }

    func testTooShortToTellAddsNothing() {
        XCTAssertEqual(PromptBuilder.languageLine(for: "hi"), "")
    }
}
