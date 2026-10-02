import XCTest
@testable import Sidekick

final class TagParserTests: XCTestCase {
    private func run(_ text: String, sizes: [Int]) -> (text: String, tags: [OverlayTag]) {
        var p = TagParser()
        var out = ""
        var tags: [OverlayTag] = []
        var idx = text.startIndex
        var i = 0
        func take(_ evs: [ParsedEvent]) {
            for e in evs {
                switch e {
                case .text(let t): out += t
                case .tag(let t): tags.append(t)
                }
            }
        }
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: sizes[i % sizes.count], limitedBy: text.endIndex) ?? text.endIndex
            take(p.push(String(text[idx..<end])))
            idx = end
            i += 1
        }
        take(p.finish())
        return (out, tags)
    }

    let sample = #"The Wi-Fi icon is up here [POINT y=12 x=880 label="Wi-Fi [menu]"] and this panel [CIRCLE y=300 x=500 r=40 label="this panel"]. [ARROW from_y=10 from_x=20 to_y=30 to_x=40 label="go"][HIGHLIGHT y1=1 x1=2 y2=3 x2=4][STEP n=2 of=5][WAIT_CLICK] Done."#

    var expectedTags: [OverlayTag] {[
        .point(y: 12, x: 880, label: "Wi-Fi [menu]"),
        .circle(y: 300, x: 500, r: 40, label: "this panel"),
        .arrow(fromY: 10, fromX: 20, toY: 30, toX: 40, label: "go"),
        .highlight(y1: 1, x1: 2, y2: 3, x2: 4, label: nil),
        .step(n: 2, of: 5),
        .waitClick,
    ]}
    let expectedText = "The Wi-Fi icon is up here  and this panel .  Done."

    func testWholeString() {
        let r = run(sample, sizes: [100_000])
        XCTAssertEqual(r.tags, expectedTags)
        XCTAssertEqual(r.text, expectedText)
    }

    func testFuzzedChunkBoundaries() {
        for _ in 0..<500 {
            let sizes = (0..<6).map { _ in Int.random(in: 1...9) }
            let r = run(sample, sizes: sizes)
            XCTAssertEqual(r.tags, expectedTags, "sizes \(sizes)")
            XCTAssertEqual(r.text, expectedText, "sizes \(sizes)")
        }
    }

    func testMalformedTagsAreDroppedNotCrashing() {
        let r = run("a [POINT x=1] b [NOPE y=1] c [POINT y=abc x=2] d [ESCALATE] e [POINT y=1 x=2", sizes: [3])
        XCTAssertEqual(r.tags, [.escalate])
        XCTAssertEqual(r.text, "a  b  c  d  e ")
    }

    func testUnbalancedOpenBracketRestartsTag() {
        let r = run("x [[POINT y=5 x=6] y", sizes: [2])
        XCTAssertEqual(r.tags, [.point(y: 5, x: 6, label: nil)])
        XCTAssertEqual(r.text, "x  y")
    }

    func testOverlongTagIsAbandoned() {
        let long = "[" + String(repeating: "a", count: 2000) + "] ok"
        let r = run(long, sizes: [50])
        XCTAssertTrue(r.tags.isEmpty)
        XCTAssertTrue(r.text.hasSuffix("] ok"))
    }

    func testAgentTypeAndEscapes() {
        let r = run(#"[AGENT task="make a \"csv\""] [TYPE text='hi, there'] [type text="lower"]"#, sizes: [4])
        XCTAssertEqual(r.tags, [.agent(task: #"make a "csv""#), .type(text: "hi, there"), .type(text: "lower")])
    }

    func testLooseNumberFormats() {
        XCTAssertEqual(TagParser.parse("POINT y=412, x=733."), .point(y: 412, x: 733, label: nil))
        XCTAssertEqual(TagParser.parse("circle x=1 y=2"), .circle(y: 2, x: 1, r: nil, label: nil))
    }

    func testReplaceTag() {
        var p = TagParser()
        let events = p.push("Done, fixed it. [REPLACE text=\"I want to know about the weather today.\"]")
        XCTAssertTrue(events.contains(.tag(.replace(text: "I want to know about the weather today."))), "\(events)")
    }
}
