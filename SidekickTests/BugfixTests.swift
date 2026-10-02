import XCTest
@testable import Sidekick

final class BugfixTests: XCTestCase {
    // Releasing ⌘ from ⌃⌥⌘ must not start push-to-talk.
    func testReleasingExtraModifierDoesNotArm() {
        var d = HoldHotkeyDetector(required: [.control, .option])
        XCTAssertNil(d.flagsChanged([.control, .option, .command], at: 0))
        XCTAssertNil(d.flagsChanged([.control, .option], at: 0.1))   // released ⌘ → not a press
        XCTAssertNil(d.tick(at: 1))
        XCTAssertNil(d.flagsChanged([], at: 1.1))
        XCTAssertEqual(d.flagsChanged([.control], at: 1.2), nil)
        XCTAssertEqual(d.flagsChanged([.control, .option], at: 1.3), .armed)   // a real press still works
    }

    // Releasing ⌥ before ⌃ after push-to-talk must not count as a bare-⌃ tap (always-on toggle).
    func testControlTapNotCountedFromPushToTalkRelease() {
        var ctrl = HoldHotkeyDetector(required: [.control])
        XCTAssertNil(ctrl.flagsChanged([.control, .option], at: 0))
        XCTAssertNil(ctrl.flagsChanged([.control], at: 0.5))     // ⌥ released first
        XCTAssertNil(ctrl.flagsChanged([], at: 0.6))             // ⌃ released → no tap
        XCTAssertEqual(ctrl.flagsChanged([.control], at: 1.0), .armed)
        XCTAssertEqual(ctrl.flagsChanged([], at: 1.05), .tap)
    }

    func testThinkingLadder() {
        XCTAssertEqual(GeminiClient.nextThinking(after: "minimal"), "low")
        XCTAssertEqual(GeminiClient.nextThinking(after: "high"), nil)
    }

    func testQuotaClassification() {
        let freeTier = "Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, model: gemini-3.8-flash\nPlease retry in 48.279610358s."
        XCTAssertFalse(GeminiClient.isPlanQuota(freeTier))
        XCTAssertEqual(GeminiClient.retryAfter(freeTier), 49)
        let noPlan = "Quota exceeded for metric: ...free_tier_input_token_count, limit: 0, model: gemini-3.1-pro"
        XCTAssertTrue(GeminiClient.isPlanQuota(noPlan))
        XCTAssertNil(GeminiClient.retryAfter("no hint"))
    }

    func testFallbackRules() {
        XCTAssertTrue(TalkCoordinator.shouldFallBack(.rateLimited("m", retryAfter: 40)))
        XCTAssertTrue(TalkCoordinator.shouldFallBack(.slow("m")))
        XCTAssertTrue(TalkCoordinator.shouldFallBack(.http(503, "high demand")))
        XCTAssertFalse(TalkCoordinator.shouldFallBack(.http(400, "bad")))
        XCTAssertFalse(TalkCoordinator.shouldFallBack(.missingKey))
        XCTAssertEqual(TalkCoordinator.blockDuration(.rateLimited("m", retryAfter: 49)), 49)
        XCTAssertEqual(TalkCoordinator.blockDuration(.quotaUnavailable("m")), 3600)
    }

    func testReadOnlyToolSetHasNoWriters() {
        let all = Set(ToolRegistry.all().map(\.name))
        XCTAssertTrue(AgentRunner.readOnlyTools.isSubset(of: all.union(["buddy_list", "wiki_search"])))
        for writer in ["files_write", "create_csv", "run_shell", "calendar_create_event", "notes_create", "ui_click", "ui_type", "open_app"] {
            XCTAssertFalse(AgentRunner.readOnlyTools.contains(writer), writer)
        }
    }
}
