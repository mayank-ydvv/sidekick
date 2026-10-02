import XCTest
@testable import Sidekick

final class WebSearchFallbackTests: XCTestCase {
    func testParsesDuckDuckGoResults() {
        let html = """
        <a rel="nofollow" class="result__a" href="https://stockanalysis.com/quote/nse/TCS/revenue/">Tata Consultancy <b>Services</b> Revenue</a>
        <a class="result__snippet" href="https://stockanalysis.com/quote/nse/TCS/revenue/">TCS had <b>revenue</b> of 2.76T &amp; growing</a>
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&rut=x">Example</a>
        """
        let out = WebTools.parseDuckDuckGo(html)
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, out)
        XCTAssertEqual(String(lines[0]), "- Tata Consultancy Services Revenue: https://stockanalysis.com/quote/nse/TCS/revenue/ — TCS had revenue of 2.76T & growing")
        XCTAssertTrue(lines[1].contains("https://example.com/a?b=1"), out)
    }
}
