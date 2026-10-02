import XCTest
import CoreGraphics
@testable import Sidekick

final class HotkeyTests: XCTestCase {
    let combo: ModifierSet = [.control, .option]

    func testHoldPastThresholdBeginsThenEnds() {
        var d = HoldHotkeyDetector(required: combo, holdThreshold: 0.15)
        XCTAssertNil(d.flagsChanged([.control], at: 0))
        XCTAssertEqual(d.flagsChanged(combo, at: 0.01), .armed)
        XCTAssertNil(d.tick(at: 0.1))
        XCTAssertEqual(d.tick(at: 0.17), .began)
        XCTAssertEqual(d.flagsChanged([.control], at: 1), .ended)
        XCTAssertEqual(d.state, .idle)
    }

    func testQuickTapCancels() {
        var d = HoldHotkeyDetector(required: combo)
        XCTAssertEqual(d.flagsChanged(combo, at: 0), .armed)
        XCTAssertEqual(d.flagsChanged([], at: 0.05), .tap)
        XCTAssertNil(d.tick(at: 0.5))
    }

    func testExtraModifierDoesNotArm() {
        var d = HoldHotkeyDetector(required: combo)
        XCTAssertNil(d.flagsChanged([.control, .option, .command], at: 0))
    }

    func testAddingModifierWhileArmedCancels() {
        var d = HoldHotkeyDetector(required: combo)
        _ = d.flagsChanged(combo, at: 0)
        XCTAssertEqual(d.flagsChanged([.control, .option, .shift], at: 0.05), .cancelled)
    }

    func testKeyDownWhileArmedCancelsButNotWhileActive() {
        var d = HoldHotkeyDetector(required: combo)
        _ = d.flagsChanged(combo, at: 0)
        XCTAssertEqual(d.keyDown(at: 0.05), .cancelled)

        _ = d.flagsChanged([], at: 0.1)
        _ = d.flagsChanged(combo, at: 0.2)
        XCTAssertEqual(d.tick(at: 0.4), .began)
        XCTAssertNil(d.keyDown(at: 0.5))
        XCTAssertEqual(d.state, .active)
    }

    func testActiveToleratesExtraModifier() {
        var d = HoldHotkeyDetector(required: combo)
        _ = d.flagsChanged(combo, at: 0)
        _ = d.tick(at: 0.2)
        XCTAssertNil(d.flagsChanged([.control, .option, .shift], at: 0.3))
        XCTAssertEqual(d.flagsChanged([.option], at: 0.4), .ended)
    }

    func testPartialReleaseIsTap() {
        var d = HoldHotkeyDetector(required: [.fn, .control])
        _ = d.flagsChanged([.fn, .control], at: 0)
        XCTAssertEqual(d.flagsChanged([.fn], at: 0.05), .tap)
    }

    func testTapCounter() {
        var c = TapCounter()
        XCTAssertEqual(c.tap(at: 1.0), 1)
        XCTAssertEqual(c.tap(at: 1.2), 2)
        XCTAssertEqual(c.tap(at: 1.45), 3)
        XCTAssertEqual(c.tap(at: 2.0), 1)
    }

    func testModifierSetFromCGFlags() {
        let s = ModifierSet(cgFlags: [.maskControl, .maskAlternate, .maskSecondaryFn])
        XCTAssertEqual(s, [.control, .option, .fn])
    }
}
