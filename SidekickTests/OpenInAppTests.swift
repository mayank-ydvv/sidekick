import XCTest
@testable import Sidekick

final class OpenInAppTests: XCTestCase {
    func testBrowserNamedInTheTask() {
        XCTAssertEqual(LocalTools.browserMentioned(in: "open github on chrome"), "Google Chrome")
        XCTAssertEqual(LocalTools.browserMentioned(in: "Open GitHub in Google Chrome please"), "Google Chrome")
        XCTAssertEqual(LocalTools.browserMentioned(in: "search youtube using firefox"), "Firefox")
        XCTAssertEqual(LocalTools.browserMentioned(in: "open chrome and go to gmail"), "Google Chrome")
        XCTAssertNil(LocalTools.browserMentioned(in: "search for edge cases in sorting"))
        XCTAssertNil(LocalTools.browserMentioned(in: "how does arc welding work"))
        XCTAssertNil(LocalTools.browserMentioned(in: "open github"))
    }

    func testBareDomainsBecomeLinks() {
        XCTAssertEqual(LocalTools.normalizeURL("github.com")?.absoluteString, "https://github.com")
        XCTAssertEqual(LocalTools.normalizeURL("www.youtube.com/watch?v=1")?.absoluteString, "https://www.youtube.com/watch?v=1")
        XCTAssertEqual(LocalTools.normalizeURL("https://github.com/x")?.absoluteString, "https://github.com/x")
        XCTAssertEqual(LocalTools.normalizeURL("spotify:search:lofi")?.absoluteString, "spotify:search:lofi")
        XCTAssertNil(LocalTools.normalizeURL("just some words"))
        XCTAssertEqual(LocalTools.normalizeURL("file:///etc/passwd")?.scheme, "file")   // parsed, then refused by allowedSchemes
        XCTAssertFalse(LocalTools.allowedSchemes.contains("file"))
    }

    @MainActor
    func testFindsAppsByShortName() {
        XCTAssertEqual(LocalTools.resolveApp("safari")?.lastPathComponent, "Safari.app")
        XCTAssertEqual(LocalTools.resolveApp("system preferences")?.lastPathComponent, "System Settings.app")
        XCTAssertEqual(LocalTools.resolveApp("com.apple.TextEdit")?.lastPathComponent, "TextEdit.app")
        if FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") {
            XCTAssertEqual(LocalTools.resolveApp("chrome")?.lastPathComponent, "Google Chrome.app")
        }
        XCTAssertNil(LocalTools.resolveApp("definitely-not-an-app-xyz"))
    }
}
