import XCTest
@testable import Sidekick

final class SettingsAndOverlayTests: XCTestCase {
    func testOldSettingsJSONKeepsValuesAndDefaultsNewKeys() throws {
        let old = #"{"fastModel":"my-flash","onboardingDone":true,"ttsRate":0.4,"pushToTalk":3}"#
        let d = try JSONDecoder().decode(SettingsData.self, from: Data(old.utf8))
        XCTAssertEqual(d.fastModel, "my-flash")
        XCTAssertTrue(d.onboardingDone)
        XCTAssertEqual(d.ttsRate, 0.4, accuracy: 1e-6)
        XCTAssertEqual(d.pushToTalk, [.control, .option])
        XCTAssertTrue(d.showBuddy)        // new key → default
        XCTAssertFalse(d.dockBuddy)
        XCTAssertEqual(d.smartModel, SettingsData().smartModel)
    }

    func testBadValueForOneKeyDoesNotWipeOthers() throws {
        let json = #"{"fastModel":"x","ttsRate":"fast"}"#
        let d = try JSONDecoder().decode(SettingsData.self, from: Data(json.utf8))
        XCTAssertEqual(d.fastModel, "x")
        XCTAssertEqual(d.ttsRate, SettingsData().ttsRate)
    }

    func testRoundTrip() throws {
        var s = SettingsData()
        s.dockBuddy = true
        s.ttsVoiceID = "com.apple.voice.premium.en-US.Zoe"
        let back = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testAXDistance() {
        let r = CGRect(x: 10, y: 10, width: 20, height: 10)
        XCTAssertEqual(AXInspector.distance(from: CGPoint(x: 15, y: 15), to: r), 0)
        XCTAssertEqual(AXInspector.distance(from: CGPoint(x: 0, y: 15), to: r), 10)
        XCTAssertEqual(AXInspector.distance(from: CGPoint(x: 33, y: 24), to: r), 5, accuracy: 1e-9)
    }

    func testTriangleCursorGeometry() {
        let box = BuddyCursorLayer.trianglePath().boundingBoxOfPath
        // Points right: the tip is the rightmost point, about tipOffset from the center.
        XCTAssertEqual(box.maxX, BuddyCursorLayer.tipOffset, accuracy: 0.01)
        XCTAssertGreaterThan(box.maxX, 4)
        XCTAssertLessThan(box.width, BuddyCursorLayer.size.width)
        // Taller than wide (play glyph), like HeyClicky's cursor.
        XCTAssertGreaterThan(box.height, box.width * 0.8)
    }

    func testNotchShapeHasEars() {
        let path = NotchShape(ear: 7, radius: 10).path(in: CGRect(x: 0, y: 0, width: 192, height: 32))
        // The top edge spans the full width (ears flare out); the body is inset by the ear.
        XCTAssertEqual(path.boundingRect.width, 192, accuracy: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: 96, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: 2, y: 20)))
    }

    func testShortTimes() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 17))!
        XCTAssertEqual(ChatStore.shortTime(now.addingTimeInterval(-20), now: now, calendar: cal), "Now")
        XCTAssertEqual(ChatStore.shortTime(now.addingTimeInterval(-86_400), now: now, calendar: cal), "Yesterday")
    }
}
