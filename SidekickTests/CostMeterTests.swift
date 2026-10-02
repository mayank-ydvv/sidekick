import XCTest
@testable import Sidekick

final class CostMeterTests: XCTestCase {
    func testCostMath() {
        let m = CostMeter(prices: ["f": ModelPrice(inputPerMillion: 1, outputPerMillion: 10)], dailyBudgetUSD: 1)
        XCTAssertEqual(m.cost(model: "f", usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 100_000)), 2.0, accuracy: 1e-9)
    }

    func testFallbackPriceForUnknownModel() {
        let m = CostMeter(prices: [:], dailyBudgetUSD: 1)
        XCTAssertGreaterThan(m.cost(model: "x", usage: TokenUsage(inputTokens: 1000, outputTokens: 0)), 0)
    }

    func testBudgetThresholds() {
        var m = CostMeter(prices: ["f": ModelPrice(inputPerMillion: 1, outputPerMillion: 0)], dailyBudgetUSD: 1)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(m.status(day), .ok)
        m.record(model: "f", usage: TokenUsage(inputTokens: 790_000, outputTokens: 0), on: day)
        XCTAssertEqual(m.status(day), .ok)
        m.record(model: "f", usage: TokenUsage(inputTokens: 20_000, outputTokens: 0), on: day)
        XCTAssertEqual(m.status(day), .warning)
        m.record(model: "f", usage: TokenUsage(inputTokens: 200_000, outputTokens: 0), on: day)
        XCTAssertEqual(m.status(day), .exceeded)
        XCTAssertEqual(m.today(day).inputTokens, 1_010_000)
        // A new day starts fresh.
        XCTAssertEqual(m.status(day.addingTimeInterval(86_400 * 2)), .ok)
    }

    func testZeroBudgetMeansUnlimited() {
        var m = CostMeter(prices: [:], dailyBudgetUSD: 0)
        m.record(model: "x", usage: TokenUsage(inputTokens: 10_000_000, outputTokens: 0))
        XCTAssertEqual(m.status(), .ok)
    }

    func testCodableRoundTrip() throws {
        var m = CostMeter(prices: ["f": ModelPrice(inputPerMillion: 1, outputPerMillion: 2)], dailyBudgetUSD: 3)
        m.record(model: "f", usage: TokenUsage(inputTokens: 5, outputTokens: 6))
        let back = try JSONDecoder().decode(CostMeter.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }
}
