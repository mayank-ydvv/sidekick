import Foundation
import Observation

/// OFF by default. Each morning (and optionally afternoon) a read-only headless agent looks at the last 48 h
/// (calendar, reminders, read-only integrations) and proposes 2 task cards for the notch.
@MainActor
@Observable
final class ProactiveSuggester {
    private(set) var cards: [SuggestionParser.Card] = []
    private var backoff: ProactiveBackoff {
        get { (UserDefaults.standard.data(forKey: "proactive.backoff")).flatMap { try? JSONDecoder().decode(ProactiveBackoff.self, from: $0) } ?? ProactiveBackoff() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "proactive.backoff") }
    }
    private var openedToday = false
    private var delivered = false
    private var timer: Timer?
    private let settings: AppSettings
    var makeRunner: () -> AgentRunner = { fatalError("set makeRunner") }

    static let morning = DateComponents(hour: 8, minute: 30)
    static let afternoon = DateComponents(hour: 14, minute: 0)

    init(settings: AppSettings) { self.settings = settings }

    func start() { arm() }

    private func arm() {
        timer?.invalidate()
        let now = Date()
        var times = [Calendar.current.nextDate(after: now, matching: Self.morning, matchingPolicy: .nextTime)]
        if settings.data.afternoonSuggestions {
            times.append(Calendar.current.nextDate(after: now, matching: Self.afternoon, matchingPolicy: .nextTime))
        }
        guard let next = times.compactMap({ $0 }).min() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer?.tolerance = 60
    }

    private func fire() {
        defer { arm() }
        guard settings.data.proactiveSuggestions else { return }
        // Close out the previous delivery for the back-off.
        if delivered {
            var b = backoff
            b.record(opened: openedToday, on: Date())
            backoff = b
            delivered = false
            openedToday = false
        }
        guard backoff.shouldRun(on: Date()) else { return }
        Task { await generate() }
    }

    func generate() async {
        let runner = makeRunner()
        let text: String = await withCheckedContinuation { cont in
            runner.onFinished = { summary, _, _ in cont.resume(returning: summary) }
            runner.start(task: """
            Look (read-only) at the user's calendar for today and tomorrow, their open reminders, and any connected \
            integrations from the last 48 hours. Propose exactly 2 concrete, helpful tasks you could do for them now. \
            Do not change anything. Reply ONLY with a JSON array: [{"title": "<6 words>", "task": "<full instruction>"}]
            """, headless: true, readOnly: true)
        }
        let parsed = SuggestionParser.parse(text)
        if !parsed.isEmpty {
            cards = parsed
            delivered = true
        }
    }

    /// The notch was opened while cards were showing.
    func markOpened() { if !cards.isEmpty { openedToday = true } }

    func dismiss(_ c: SuggestionParser.Card) { cards.removeAll { $0 == c } }
}
