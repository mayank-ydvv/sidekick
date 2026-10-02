import XCTest
@testable import Sidekick

@MainActor
final class ModelHealthTests: XCTestCase {
    override func setUp() async throws { ModelHealth.reset() }
    override func tearDown() async throws { ModelHealth.reset() }

    func testRepeatedFailuresBackOffAndSuccessClears() {
        let now = Date()
        ModelHealth.block("m", for: .rateLimited("m", retryAfter: 20), now: now)
        let first = ModelHealth.until("m").timeIntervalSince(now)
        ModelHealth.block("m", for: .rateLimited("m", retryAfter: 20), now: now)
        let second = ModelHealth.until("m").timeIntervalSince(now)
        XCTAssertEqual(first, 30, accuracy: 1)
        XCTAssertEqual(second, 60, accuracy: 1)
        XCTAssertTrue(ModelHealth.isBlocked("m", now: now))
        ModelHealth.succeeded("m")
        XCTAssertFalse(ModelHealth.isBlocked("m", now: now))
    }

    func testPlanQuotaBlocksForHours() {
        let now = Date()
        ModelHealth.block("pro", for: .quotaUnavailable("pro"), now: now)
        XCTAssertGreaterThan(ModelHealth.until("pro").timeIntervalSince(now), 5 * 3600)
    }
}
