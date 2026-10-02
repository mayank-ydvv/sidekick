import XCTest
@testable import Sidekick

final class TeachingTests: XCTestCase {
    let target = TeachTarget(point: CGPoint(x: 100, y: 100), frame: CGRect(x: 80, y: 90, width: 60, height: 20), label: "New Folder")

    func testFullStepCycle() {
        var t = TeachingSession()
        XCTAssertFalse(t.isActive)
        t.replyStarted()
        t.onStep(n: 1, of: 3)
        t.onTarget(target)
        t.onWaitClick()
        XCTAssertEqual(t.stepLabel, "step 1 of 3")
        XCTAssertTrue(t.replyFinished())
        XCTAssertEqual(t.phase, .waitingForClick)

        XCTAssertEqual(t.click(at: CGPoint(x: 400, y: 400)), .miss(hints: 1))
        XCTAssertEqual(t.click(at: CGPoint(x: 400, y: 400)), .miss(hints: 2))
        XCTAssertEqual(t.click(at: CGPoint(x: 135, y: 95)), .hit)      // inside frame
        XCTAssertEqual(t.phase, .verifying)
        XCTAssertEqual(t.click(at: CGPoint(x: 135, y: 95)), .ignored)  // no double counting

        // Next step arrives, then the final reply has no WAIT_CLICK → lesson ends.
        t.replyStarted()
        t.onStep(n: 2, of: nil)
        XCTAssertEqual(t.stepLabel, "step 2 of 3")
        XCTAssertFalse(t.replyFinished())
        XCTAssertFalse(t.isActive)
    }

    func testHitWithinPointToleranceWithoutFrame() {
        let t = TeachTarget(point: CGPoint(x: 10, y: 10), frame: nil, label: nil)
        XCTAssertTrue(t.isHit(CGPoint(x: 30, y: 30)))    // ~28 pt away
        XCTAssertFalse(t.isHit(CGPoint(x: 40, y: 40)))
    }

    func testFramePadding() {
        XCTAssertTrue(target.isHit(CGPoint(x: 145, y: 112)))   // just outside frame, within 6 pt padding
    }

    func testWaitClickWithoutTargetDoesNotWait() {
        var t = TeachingSession()
        t.replyStarted()
        t.onWaitClick()
        XCTAssertFalse(t.replyFinished())
        XCTAssertEqual(t.phase, .explaining)
    }

    func testNormalAnswerDoesNotStartLesson() {
        var t = TeachingSession()
        t.replyStarted()
        XCTAssertFalse(t.replyFinished())
        XCTAssertFalse(t.isActive)
    }

    func testCommands() {
        XCTAssertEqual(TeachingSession.command(from: "Stop."), .stop)
        XCTAssertEqual(TeachingSession.command(from: " skip this step "), .skip)
        XCTAssertEqual(TeachingSession.command(from: "Go back!"), .back)
        XCTAssertEqual(TeachingSession.command(from: "band karo"), .stop)
        XCTAssertNil(TeachingSession.command(from: "how do I stop the music from playing"))
        XCTAssertNil(TeachingSession.command(from: "next to the button what's that"))
    }
}

final class ModelRouterTests: XCTestCase {
    func testAutoRouting() {
        XCTAssertEqual(ModelRouter.route("what's on my screen?", mode: .auto), .fast)
        XCTAssertEqual(ModelRouter.route("Think hard about why this test fails", mode: .auto), .smart)
        XCTAssertEqual(ModelRouter.route("explain in detail how this chart works", mode: .auto), .smart)
        XCTAssertEqual(ModelRouter.route("isko detail mein samjhao", mode: .auto), .smart)
        let long = Array(repeating: "word", count: 50).joined(separator: " ")
        XCTAssertEqual(ModelRouter.route(long, mode: .auto), .smart)
    }

    func testForcedModes() {
        XCTAssertEqual(ModelRouter.route("think hard", mode: .fast), .fast)
        XCTAssertEqual(ModelRouter.route("hi", mode: .smart), .smart)
    }
}

final class AppSkillsTests: XCTestCase {
    func testFrontmatterParsing() {
        let text = "---\nname: X\nmatch: com.a.b, Example.com\n---\nBody line"
        XCTAssertEqual(AppSkillsLoader.matchKeys(in: text), ["com.a.b", "example.com"])
        XCTAssertEqual(AppSkillsLoader.stripFrontmatter(text), "Body line")
        XCTAssertEqual(AppSkillsLoader.matchKeys(in: "no frontmatter"), [])
    }

    func testDomainCandidates() {
        XCTAssertEqual(AppSkillsLoader.domainCandidates("www.docs.google.com"), ["docs.google.com", "google.com"])
        XCTAssertEqual(AppSkillsLoader.host(of: "https://mail.google.com/mail/u/0/#inbox"), "mail.google.com")
        XCTAssertEqual(AppSkillsLoader.host(of: "figma.com/file/abc"), "figma.com")
    }

    func testLookupPrefersSiteOverBrowserAndUserOverrides() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = tmp.appendingPathComponent("bundled"), user = tmp.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try "---\nmatch: com.google.chrome\n---\nCHROME".write(to: bundled.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        try "---\nmatch: docs.google.com\n---\nDOCS".write(to: bundled.appendingPathComponent("d.md"), atomically: true, encoding: .utf8)
        try "---\nmatch: com.apple.finder\n---\nBUNDLED FINDER".write(to: bundled.appendingPathComponent("f.md"), atomically: true, encoding: .utf8)
        try "---\nmatch: com.apple.finder\n---\nMY FINDER".write(to: user.appendingPathComponent("f.md"), atomically: true, encoding: .utf8)
        let loader = AppSkillsLoader(directories: [bundled, user])
        XCTAssertEqual(loader.skill(bundleID: "com.google.Chrome", url: "https://docs.google.com/document/d/1"), "DOCS")
        XCTAssertEqual(loader.skill(bundleID: "com.google.Chrome", url: "https://example.com"), "CHROME")
        XCTAssertEqual(loader.skill(bundleID: "com.apple.finder", url: nil), "MY FINDER")
        XCTAssertNil(loader.skill(bundleID: "com.unknown", url: nil))
        try? FileManager.default.removeItem(at: tmp)
    }

    func testBundledSkillsAllHaveMatchKeys() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sidekick/Resources/AppSkills")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertGreaterThanOrEqual(files.count, 21)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(AppSkillsLoader.matchKeys(in: text).isEmpty, f.lastPathComponent)
        }
    }
}

final class InkBurnTests: XCTestCase {
    func testInkIsDrawnRedAtMappedLocation() throws {
        let w = 200, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        // Display 400x200 pt at origin; image is half size.
        let mapper = CoordinateMapper(displayFrame: CGRect(x: 0, y: 0, width: 400, height: 200), imageSize: CGSize(width: w, height: h))
        let shot = ScreenContext(jpeg: Data(), image: img, mapper: mapper, mouse: .zero)
        // Horizontal stroke across the top quarter of the display (AppKit y=150 → image row 25 from top).
        let out = ScreenCapturer.burnInk([[CGPoint(x: 40, y: 150), CGPoint(x: 360, y: 150)]], into: shot)
        XCTAssertFalse(out.jpeg.isEmpty)
        let px = pixel(out.image, x: 100, yFromTop: 25)
        XCTAssertGreaterThan(px.r, 200); XCTAssertLessThan(px.g, 60)
        let clean = pixel(out.image, x: 100, yFromTop: 75)
        XCTAssertGreaterThan(clean.g, 200)
    }

    private func pixel(_ img: CGImage, x: Int, yFromTop: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - yFromTop), width: img.width, height: img.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
