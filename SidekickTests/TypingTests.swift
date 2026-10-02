import XCTest
@testable import Sidekick

final class TypingTests: XCTestCase {
    func testAllCapsBecomesNormalCase() {
        XCTAssertEqual(ComputerUse.normalCase("RAVI SHARMA", request: "search for ravi sharma"), "Ravi Sharma")
        XCTAssertEqual(ComputerUse.normalCase("HEY", request: "send hey to ravi sharma"), "Hey")
        XCTAssertEqual(ComputerUse.normalCase("HEY, ARE YOU COMING TONIGHT? I WILL BE THERE AT 8.", request: "tell him"),
                       "Hey, are you coming tonight? I will be there at 8.")
    }

    func testNormalTextAndRequestedCapitalsAreKept() {
        XCTAssertEqual(ComputerUse.normalCase("Hey Ravi", request: "x"), "Hey Ravi")
        XCTAssertEqual(ComputerUse.normalCase("hello there", request: "x"), "hello there")
        XCTAssertEqual(ComputerUse.normalCase("NASA", request: "type NASA in the search box"), "NASA")
        XCTAssertEqual(ComputerUse.normalCase("OK", request: "reply OK to him"), "OK")
        XCTAssertEqual(ComputerUse.normalCase("123 456", request: "x"), "123 456")
    }

    func testTypedTextShowsInTaskSteps() {
        let tool = ComputerUse.all.first { $0.name == "ui_type" }!
        XCTAssertEqual(tool.summary(["text": "Hey"]), "ui_type: \"Hey\"")
        XCTAssertEqual(tool.summary(["text": "123456"]), "ui_type: ••••")
    }
}
