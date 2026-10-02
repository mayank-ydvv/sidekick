import XCTest
@testable import Sidekick

final class UtteranceSegmenterTests: XCTestCase {
    /// Feeds a level timeline at 30 Hz; returns the events.
    private func run(_ timeline: [(TimeInterval, Float)], until end: TimeInterval) -> [UtteranceSegmenter.Event] {
        var seg = UtteranceSegmenter()
        var out: [UtteranceSegmenter.Event] = []
        var t = 0.0
        while t <= end {
            let level = timeline.last(where: { $0.0 <= t })?.1 ?? 0
            if let e = seg.feed(level: level, at: t) { out.append(e) }
            t += 1.0 / 30
        }
        return out
    }

    func testSegmentsOneUtterance() {
        let ev = run([(0, 0), (1.0, 0.3), (2.5, 0.01)], until: 4)
        XCTAssertEqual(ev.count, 2)
        guard case .started(let s) = ev[0], case .ended(let s2, let e) = ev[1] else { return XCTFail() }
        XCTAssertEqual(s, 1.0, accuracy: 0.05)
        XCTAssertEqual(s2, s)
        XCTAssertEqual(e, 2.5 + 0.15, accuracy: 0.1)
    }

    func testShortPausesDontSplit() {
        // 0.3 s dip is shorter than the 0.6 s end-silence.
        let ev = run([(0, 0.3), (1.0, 0.0), (1.3, 0.3), (2.0, 0.0)], until: 3.5)
        XCTAssertEqual(ev.filter { if case .ended = $0 { return true }; return false }.count, 1)
    }

    func testClicksAndBlipsIgnored() {
        XCTAssertTrue(run([(0, 0), (1.0, 0.5), (1.05, 0)], until: 3).isEmpty)          // < start hold
        let ev = run([(0, 0), (1.0, 0.5), (1.2, 0)], until: 3)                          // too short overall
        XCTAssertFalse(ev.contains { if case .ended = $0 { return true }; return false })
    }

    func testMaxLengthCuts() {
        let ev = run([(0, 0.4)], until: 32)
        let ended = ev.compactMap { e -> (TimeInterval, TimeInterval)? in
            if case .ended(let s, let e) = e { return (s, e) }; return nil
        }
        guard let (s, e) = ended.first else { return XCTFail() }
        XCTAssertEqual(e - s, 30, accuracy: 0.2)
    }
}

final class AXTreeTests: XCTestCase {
    func testFormatUsesNormalizedCenters() {
        let mapper = CoordinateMapper(displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), imageSize: CGSize(width: 1000, height: 1000))
        let nodes = [AXNode(id: 0, role: "AXButton", title: "Search", frame: CGRect(x: 100, y: 800, width: 100, height: 100))]
        XCTAssertEqual(AXTree.format(nodes, mapper: mapper, menus: ["File", "Edit"]),
                       "menus: File | Edit\n[0] Button \"Search\" @y=150 x=150")
    }

    func testMenuPath() {
        XCTAssertEqual(AXTree.menuPath("File > New Folder"), ["File", "New Folder"])
        XCTAssertEqual(AXTree.menuPath("View→Show Sidebar"), ["View", "Show Sidebar"])
    }

    func testKeyCombos() {
        let (k, f) = AXTree.keyCombo("cmd+shift+n")!
        XCTAssertEqual(k, 45)
        XCTAssertEqual(f, [.maskCommand, .maskShift])
        XCTAssertEqual(AXTree.keyCombo("Return")?.0, 36)
        XCTAssertNil(AXTree.keyCombo("cmd+banana"))
    }

    func testSensitiveTextRefused() {
        XCTAssertTrue(ComputerUse.looksSensitive("4111 1111 1111 1111"))
        XCTAssertTrue(ComputerUse.looksSensitive("482913"))
        XCTAssertFalse(ComputerUse.looksSensitive("lofi beats"))
        XCTAssertFalse(ComputerUse.looksSensitive("2026"))
    }

    func testOnlyNewestScreenshotKept() {
        var contents: [[String: Any]] = [
            ["role": "user", "parts": [["text": "task"], ["inlineData": ["data": "old"]]]],
            ["role": "model", "parts": [["text": "ok"]]],
        ]
        AgentRunner.dropOldImages(&contents)
        XCTAssertEqual((contents[0]["parts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((contents[1]["parts"] as? [[String: Any]])?.count, 1)
    }

    func testChunked() {
        XCTAssertEqual("abcdefg".chunked(3), ["abc", "def", "g"])
    }

    func testAppLinkAllowlist() {
        XCTAssertTrue(LocalTools.allowedSchemes.contains("spotify"))
        XCTAssertFalse(LocalTools.allowedSchemes.contains("file"))
        XCTAssertFalse(LocalTools.allowedSchemes.contains("javascript"))
    }
}
