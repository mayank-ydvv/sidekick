import XCTest
@testable import Sidekick

final class MathTextTests: XCTestCase {
    func testSimpleInterestAnswerFromScreenshot() {
        let raw = """
        $$\\text{Interest} = P \\times r \\times t$$
        - $P$ = Principal amount ($3000)
        - $r$ = Annual interest rate ($4% = 0.04$)
        - $t$ = Time in years ($5$)
        - $3000 \\times 0.04 = 120$
        """
        let out = MathText.clean(raw)
        XCTAssertFalse(out.contains("\\"), out)
        XCTAssertTrue(out.contains("**Interest = P × r × t**"), out)
        XCTAssertTrue(out.contains("- P = Principal amount ($3000)"), out)
        XCTAssertTrue(out.contains("(4% = 0.04)"), out)
        XCTAssertTrue(out.contains("(5)"), out)
        XCTAssertTrue(out.contains("3000 × 0.04 = 120"), out)
    }

    func testFractionsPowersAndRoots() {
        XCTAssertEqual(MathText.clean("$\\frac{92}{120} \\times 100$"), "92/120 × 100")
        XCTAssertEqual(MathText.clean("$x^2 + y^{3}$"), "x² + y³")
        XCTAssertEqual(MathText.clean("$\\sqrt{16} = 4$"), "√16 = 4")
        XCTAssertEqual(MathText.clean("$\\frac{a+b}{2}$"), "(a+b)/2")
    }

    func testCurrencyAndCodeAreLeftAlone() {
        XCTAssertEqual(MathText.clean("It costs $5, or $10 with tax."), "It costs $5, or $10 with tax.")
        let code = "```latex\n$\\frac{1}{2}$\n```"
        XCTAssertEqual(MathText.clean(code), code)
        XCTAssertEqual(MathText.clean("Profit = $240 − $200 = $40"), "Profit = $240 − $200 = $40")
    }

    func testMultilineDisplayBlock() {
        XCTAssertEqual(MathText.clean("$$\n\\text{Profit\\%} = \\frac{40}{200} \\times 100\n$$"), "**Profit% = 40/200 × 100**")
    }

    func testCodeAndPathsKeepTheirBackslashes() {
        XCTAssertEqual(MathText.clean("Use `print(\"a\\nb\")` and `$x$` here"), "Use `print(\"a\\nb\")` and `$x$` here")
        XCTAssertEqual(MathText.clean("Open C:\\Users\\mayank\\notes"), "Open C:\\Users\\mayank\\notes")
        XCTAssertEqual(MathText.clean("Area = 3 \\times 4 = 12"), "Area = 3 × 4 = 12")
    }
}
