import Foundation

/// Shared memory of models that recently failed for this key (used-up free quota, not on the plan), so voice,
/// chat, tasks and web search all skip them for a while instead of each re-trying (and waiting on) them.
@MainActor
enum ModelHealth {
    private(set) static var blockedUntil: [String: Date] = load() {
        didSet { save() }
    }
    private static let key = "modelHealth.blockedUntil"

    private static func load() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value > Date() }
    }

    private static func save() {
        UserDefaults.standard.set(blockedUntil.filter { $0.value > Date() }.mapValues(\.timeIntervalSince1970), forKey: key)
    }
    private static var streak: [String: Int] = [:]

    static func isBlocked(_ model: String, now: Date = Date()) -> Bool {
        (blockedUntil[model] ?? .distantPast) > now
    }

    static func until(_ model: String) -> Date { blockedUntil[model] ?? .distantPast }

    /// Records a failure; repeated failures double the wait (up to an hour; plan quota: 6 hours).
    static func block(_ model: String, for error: GeminiError, now: Date = Date()) {
        let n = (streak[model] ?? 0) + 1
        streak[model] = n
        let base: TimeInterval
        switch error {
        case .quotaUnavailable: base = 6 * 3600
        default: base = min(3600, TalkCoordinator.blockDuration(error) * pow(2, Double(n - 1)))
        }
        blockedUntil[model] = now.addingTimeInterval(base)
    }

    static func succeeded(_ model: String) {
        streak[model] = nil
        blockedUntil[model] = nil
    }

    static func reset() { blockedUntil = [:]; streak = [:] }
}
