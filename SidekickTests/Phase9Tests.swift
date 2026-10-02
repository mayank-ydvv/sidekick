import XCTest
@testable import Sidekick

final class SettingsMapTests: XCTestCase {
    func testPrepareAndApplyVoiceSpeed() {
        var d = SettingsData()
        d.ttsRate = 0.52
        let c = SettingsMap.prepare(key: "voice_speed", value: "slower", current: d)
        XCTAssertEqual(c?.description, "talk slower")
        SettingsMap.apply(c!, to: &d)
        XCTAssertEqual(d.ttsRate, 0.46, accuracy: 1e-4)
        // Clamped at the slowest rate.
        d.ttsRate = 0.36
        SettingsMap.apply(SettingsMap.prepare(key: "voice_speed", value: "slower", current: d)!, to: &d)
        XCTAssertEqual(d.ttsRate, 0.35, accuracy: 1e-4)
    }

    func testOtherKeys() {
        var d = SettingsData()
        for (k, v) in [("voice", "off"), ("buddy", "dock"), ("model", "smart"), ("language", "hi"),
                       ("speech_model", "base"), ("dictation_polish", "on"), ("suggestions", "on"), ("quiet_mode", "off")] {
            SettingsMap.apply(SettingsMap.prepare(key: k, value: v, current: d)!, to: &d)
        }
        XCTAssertTrue(d.textOnly)
        XCTAssertTrue(d.dockBuddy)
        XCTAssertEqual(d.modelTier, .smart)
        XCTAssertEqual(d.language, "hi")
        XCTAssertEqual(d.whisperModel, .base)
        XCTAssertTrue(d.polishDictation)
        XCTAssertTrue(d.proactiveSuggestions)
        XCTAssertFalse(d.quietMode)
        SettingsMap.apply(SettingsMap.prepare(key: "language", value: "auto", current: d)!, to: &d)
        XCTAssertEqual(d.language, "")
    }

    func testRejectsUnknownOrInvalid() {
        let d = SettingsData()
        XCTAssertNil(SettingsMap.prepare(key: "api_key", value: "x", current: d))
        XCTAssertNil(SettingsMap.prepare(key: "voice", value: "loud", current: d))
        XCTAssertNil(SettingsMap.prepare(key: "model", value: "gpt", current: d))
    }

    func testYesNo() {
        XCTAssertTrue(SettingsMap.isYes("yes please"))
        XCTAssertTrue(SettingsMap.isYes("haan kar do"))
        XCTAssertTrue(SettingsMap.isNo("no thanks"))
        XCTAssertFalse(SettingsMap.isYes("what's the weather"))
    }

    func testSettingTagParses() {
        XCTAssertEqual(TagParser.parse(#"SETTING key="voice_speed" value="slower""#), .setting(key: "voice_speed", value: "slower"))
        XCTAssertNil(TagParser.parse(#"SETTING key="voice_speed""#))
    }
}

final class ProactiveTests: XCTestCase {
    let cal = Calendar(identifier: .gregorian)

    func testBackoffDoublesUpToSevenDays() {
        var b = ProactiveBackoff()
        var day = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        func ignore(_ n: Int) { for _ in 0..<n { b.record(opened: false, on: day); day = day.addingTimeInterval(86_400) } }
        ignore(2)
        XCTAssertNil(b.pausedUntil)
        ignore(1)
        XCTAssertEqual(b.pauseDays, 1)
        XCTAssertFalse(b.shouldRun(on: day.addingTimeInterval(-3600)))
        ignore(3); XCTAssertEqual(b.pauseDays, 2)
        ignore(3); XCTAssertEqual(b.pauseDays, 4)
        ignore(3); XCTAssertEqual(b.pauseDays, 7)
        ignore(3); XCTAssertEqual(b.pauseDays, 7)
        b.record(opened: true, on: day)
        XCTAssertEqual(b, ProactiveBackoff())
        XCTAssertTrue(b.shouldRun(on: day))
    }

    func testSuggestionParser() {
        let text = #"Here you go: [{"title":"Prep for 3pm","task":"Summarize notes for the 3pm meeting"},{"title":"Reply to Anu","task":"Draft a reply"},{"title":"Third","task":"x"}] done"#
        let cards = SuggestionParser.parse(text)
        XCTAssertEqual(cards.map(\.title), ["Prep for 3pm", "Reply to Anu"])
        XCTAssertTrue(SuggestionParser.parse("no json here").isEmpty)
        XCTAssertTrue(SuggestionParser.parse(#"[{"title":"","task":"x"}]"#).isEmpty)
    }
}

final class FriendlyErrorTests: XCTestCase {
    func testMessages() {
        XCTAssertTrue(Friendly.message(URLError(.notConnectedToInternet)).contains("offline"))
        XCTAssertTrue(Friendly.message(URLError(.timedOut)).contains("too long"))
        XCTAssertTrue(Friendly.message(TimeoutError()).contains("too long"))
        XCTAssertEqual(Friendly.message(GeminiError.missingKey), "add your gemini api key in settings first")
    }
}
