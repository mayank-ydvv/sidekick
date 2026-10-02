import XCTest
@testable import Sidekick

final class TextCleanerTests: XCTestCase {
    func testRemovesFillersAndCapitalizes() {
        XCTAssertEqual(TextCleaner.clean("um so I think uh we should go"), "So I think we should go")
    }

    func testSpokenPunctuationAndNewLines() {
        XCTAssertEqual(TextCleaner.clean("hello comma how are you question mark new line thanks period"),
                       "Hello, how are you?\nThanks.")
        XCTAssertEqual(TextCleaner.clean("first point new paragraph second point full stop"),
                       "First point\n\nSecond point.")
    }

    func testDoesNotDoublePunctuateWhisperOutput() {
        XCTAssertEqual(TextCleaner.clean("Hello, comma world."), "Hello, world.")
    }

    func testFillerWithPunctuationAttached() {
        XCTAssertEqual(TextCleaner.clean("Um, I need, uh, the report."), "I need, the report.")
    }

    func testCapitalizesEachSentence() {
        XCTAssertEqual(TextCleaner.capitalizeSentences("hi. how are you? fine"), "Hi. How are you? Fine")
    }

    func testHinglishUntouched() {
        XCTAssertEqual(TextCleaner.clean("kal meeting hai na"), "Kal meeting hai na")
    }
}

final class DictionaryTests: XCTestCase {
    let entries = [
        DictionaryEntry(wrong: "clode", right: "Claude", hits: 2, updatedAt: Date()),
        DictionaryEntry(wrong: "my unk", right: "Mayank", hits: 1, updatedAt: Date()),
    ]

    func testApplyWholeWordsCaseInsensitive() {
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "Ask Clode and my unk. clodes stay."),
                       "Ask Claude and Mayank. clodes stay.")
    }

    func testApplyEmpty() {
        XCTAssertEqual(PersonalDictionary.apply([], to: "same"), "same")
    }

    @MainActor
    func testLearnAndPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let d = PersonalDictionary(url: url)
        d.learn(wrong: "clode", right: "Claude")
        d.learn(wrong: "Clode", right: "Claude")
        XCTAssertEqual(d.entries.count, 1)
        XCTAssertEqual(d.entries[0].hits, 2)
        d.learn(wrong: "same", right: "same")
        XCTAssertEqual(d.entries.count, 1)
        let reloaded = PersonalDictionary(url: url)
        XCTAssertEqual(reloaded.entries.map(\.right), ["Claude"])
        XCTAssertEqual(reloaded.promptWords, "Claude")
        try? FileManager.default.removeItem(at: url)
    }
}

final class CorrectionLearnerTests: XCTestCase {
    func testLearnsSingleWordFix() {
        let before = "Notes: ask Clode about it"
        let inserted = NSRange(location: 7, length: 18)   // "ask Clode about it"
        let r = CorrectionLearner.learn(before: before, after: "Notes: ask Claude about it", inserted: inserted)
        XCTAssertEqual(r?.wrong, "Clode")
        XCTAssertEqual(r?.right, "Claude")
    }

    func testIgnoresEditsOutsideInsertedText() {
        let before = "Notes: ask Clode about it"
        let r = CorrectionLearner.learn(before: before, after: "Nots: ask Clode about it", inserted: NSRange(location: 7, length: 18))
        XCTAssertNil(r)
    }

    func testIgnoresRewritesAndDeletions() {
        let before = "send the report"
        let all = NSRange(location: 0, length: 15)
        XCTAssertNil(CorrectionLearner.learn(before: before, after: "send the quarterly financial summary deck", inserted: all))
        XCTAssertNil(CorrectionLearner.learn(before: before, after: "send the ", inserted: all))
        XCTAssertNil(CorrectionLearner.learn(before: before, after: before, inserted: all))
    }

    func testCapitalizationFix() {
        let r = CorrectionLearner.learn(before: "hi mayank", after: "hi Mayank", inserted: NSRange(location: 0, length: 9))
        XCTAssertEqual(r?.wrong, "mayank")
        XCTAssertEqual(r?.right, "Mayank")
    }

    func testLevenshtein() {
        XCTAssertEqual(CorrectionLearner.levenshtein(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(CorrectionLearner.levenshtein(Array(""), Array("abc")), 3)
    }
}
