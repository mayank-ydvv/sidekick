import Foundation

/// USD price per 1M tokens.
struct ModelPrice: Codable, Equatable, Sendable {
    var inputPerMillion: Double
    var outputPerMillion: Double
}

enum BudgetStatus: Equatable { case ok, warning, exceeded }

/// Tracks token usage and estimated cost per day. Pure logic; persistence is injected.
struct CostMeter: Codable, Equatable {
    struct Day: Codable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var costUSD = 0.0
    }

    var prices: [String: ModelPrice]
    var fallbackPrice = ModelPrice(inputPerMillion: 0.5, outputPerMillion: 3.0)
    var dailyBudgetUSD: Double
    var warnFraction = 0.8
    /// key: "yyyy-MM-dd"
    private(set) var days: [String: Day] = [:]

    init(prices: [String: ModelPrice], dailyBudgetUSD: Double) {
        self.prices = prices
        self.dailyBudgetUSD = dailyBudgetUSD
    }

    func cost(model: String, usage: TokenUsage) -> Double {
        let p = prices[model] ?? fallbackPrice
        return Double(usage.inputTokens) / 1_000_000 * p.inputPerMillion
             + Double(usage.outputTokens) / 1_000_000 * p.outputPerMillion
    }

    @discardableResult
    mutating func record(model: String, usage: TokenUsage, on date: Date = Date()) -> Double {
        let c = cost(model: model, usage: usage)
        let key = Self.dayKey(date)
        var d = days[key] ?? Day()
        d.inputTokens += usage.inputTokens
        d.outputTokens += usage.outputTokens
        d.costUSD += c
        days[key] = d
        // Keep 60 days of history at most.
        if days.count > 60, let oldest = days.keys.min() { days[oldest] = nil }
        return c
    }

    func today(_ date: Date = Date()) -> Day { days[Self.dayKey(date)] ?? Day() }

    func status(_ date: Date = Date()) -> BudgetStatus {
        guard dailyBudgetUSD > 0 else { return .ok }
        let spent = today(date).costUSD
        if spent >= dailyBudgetUSD { return .exceeded }
        if spent >= dailyBudgetUSD * warnFraction { return .warning }
        return .ok
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
