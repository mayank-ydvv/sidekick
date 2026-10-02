import XCTest
@testable import Sidekick

final class SentenceSplitterTests: XCTestCase {
    private func run(_ text: String, chunkSizes: [Int]) -> [String] {
        var s = SentenceSplitter()
        var out: [String] = []
        var idx = text.startIndex
        var i = 0
        while idx < text.endIndex {
            let n = chunkSizes[i % chunkSizes.count]
            let end = text.index(idx, offsetBy: n, limitedBy: text.endIndex) ?? text.endIndex
            out += s.push(String(text[idx..<end]))
            idx = end
            i += 1
        }
        if let rest = s.finish() { out.append(rest) }
        return out
    }

    let sample = #"That's the Finder. Click the **Export** button [POINT y=412 x=733 label="Export button"] at the top right! See https://example.com/docs for more. Version 3.5 is out"#

    let expected = [
        "That's the Finder.",
        "Click the Export button at the top right!",
        "See link for more.",
        "Version 3.5 is out",
    ]

    func testWholeString() {
        XCTAssertEqual(run(sample, chunkSizes: [10_000]), expected)
    }

    func testFuzzedChunkBoundaries() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let sizes = (0..<8).map { _ in Int.random(in: 1...12, using: &rng) }
            XCTAssertEqual(run(sample, chunkSizes: sizes), expected, "sizes \(sizes)")
        }
    }

    func testOneCharAtATime() {
        XCTAssertEqual(run(sample, chunkSizes: [1]), expected)
    }

    func testUnclosedTagIsDropped() {
        XCTAssertEqual(run("Hi there. [POINT y=1", chunkSizes: [3]), ["Hi there."])
    }

    func testNewlineEndsSentence() {
        XCTAssertEqual(run("first line\nsecond", chunkSizes: [4]), ["first line", "second"])
    }

    func testHindiDanda() {
        XCTAssertEqual(run("यह फाइंडर है। ठीक है", chunkSizes: [2]), ["यह फाइंडर है।", "ठीक है"])
    }

    func testFirstClauseEmittedEarlyAtComma() {
        let text = "Looks like you're in Finder, with your Desktop folder open. Want me to tidy it, sort by date, or leave it?"
        XCTAssertEqual(run(text, chunkSizes: [5]), [
            "Looks like you're in Finder,",
            "with your Desktop folder open.",
            "Want me to tidy it, sort by date, or leave it?",
        ])
    }

    func testNumbersWithCommasAreNotSplit() {
        XCTAssertEqual(run("The total comes to about 1,250,000 rupees for the year.", chunkSizes: [3]),
                       ["The total comes to about 1,250,000 rupees for the year."])
    }

    func testStripTags() {
        XCTAssertEqual(SentenceSplitter.stripTags("a [X y=1] b [WAIT_CLICK]"), "a  b ")
    }
}
