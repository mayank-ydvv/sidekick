import AppKit
import EventKit
import Observation

/// One countdown timer and one stopwatch (like iPhone's Clock live activities). Survive restarts.
@MainActor
@Observable
final class TimerStore {
    struct Timer: Equatable, Codable {
        var label: String
        var total: TimeInterval
        /// When it ends (running) — or nil while paused, with `remainingWhenPaused` set.
        var ends: Date?
        var remainingWhenPaused: TimeInterval?

        var running: Bool { ends != nil }
        func remaining(at now: Date = Date()) -> TimeInterval {
            if let ends { return max(0, ends.timeIntervalSince(now)) }
            return remainingWhenPaused ?? total
        }
        var progress: Double { total > 0 ? 1 - remaining() / total : 0 }
    }

    struct Stopwatch: Equatable, Codable {
        var start: Date
        var accumulated: TimeInterval
        var running: Bool
        func elapsed(at now: Date = Date()) -> TimeInterval { accumulated + (running ? now.timeIntervalSince(start) : 0) }
    }

    private(set) var timer: Timer? { didSet { save() } }
    private(set) var stopwatch: Stopwatch? { didSet { save() } }
    var onFinished: ((Timer) -> Void)?
    private var fire: DispatchWorkItem?

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "island.timer"), let t = try? JSONDecoder().decode(Timer.self, from: data) { timer = t }
        if let data = d.data(forKey: "island.stopwatch"), let s = try? JSONDecoder().decode(Stopwatch.self, from: data) { stopwatch = s }
        schedule()
    }

    // MARK: Timer

    func startTimer(seconds: TimeInterval, label: String = "") {
        guard seconds > 0 else { return }
        timer = Timer(label: label.isEmpty ? Self.describe(seconds) : label, total: seconds, ends: Date().addingTimeInterval(seconds))
        schedule()
    }

    func pauseTimer() {
        guard var t = timer, t.running else { return }
        t.remainingWhenPaused = t.remaining(); t.ends = nil
        timer = t; schedule()
    }

    func resumeTimer() {
        guard var t = timer, !t.running else { return }
        t.ends = Date().addingTimeInterval(t.remainingWhenPaused ?? t.total); t.remainingWhenPaused = nil
        timer = t; schedule()
    }

    func addMinute() {
        guard var t = timer else { return }
        t.total += 60
        if let e = t.ends { t.ends = e.addingTimeInterval(60) } else { t.remainingWhenPaused = (t.remainingWhenPaused ?? 0) + 60 }
        timer = t; schedule()
    }

    func cancelTimer() { timer = nil; schedule() }

    private func schedule() {
        fire?.cancel()
        guard let t = timer, let ends = t.ends else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, let cur = self.timer, cur.ends == ends else { return }
            self.timer = nil
            self.onFinished?(cur)
        }
        fire = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ends.timeIntervalSinceNow), execute: w)
    }

    // MARK: Stopwatch

    func stopwatchStart() {
        if var s = stopwatch, !s.running { s.start = Date(); s.running = true; stopwatch = s }
        else if stopwatch == nil { stopwatch = Stopwatch(start: Date(), accumulated: 0, running: true) }
    }

    func stopwatchPause() {
        guard var s = stopwatch, s.running else { return }
        s.accumulated = s.elapsed(); s.running = false
        stopwatch = s
    }

    func stopwatchReset() { stopwatch = nil }

    private func save() {
        let d = UserDefaults.standard
        if let timer, let data = try? JSONEncoder().encode(timer) { d.set(data, forKey: "island.timer") } else { d.removeObject(forKey: "island.timer") }
        if let stopwatch, let data = try? JSONEncoder().encode(stopwatch) { d.set(data, forKey: "island.stopwatch") } else { d.removeObject(forKey: "island.stopwatch") }
    }

    /// "10 min", "1 h 30 min", "45 s".
    nonisolated static func describe(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        if m > 0 { return sec > 0 ? "\(m) min \(sec) s" : "\(m) min" }
        return "\(sec) s"
    }

    /// "4:59", "1:02:03".
    nonisolated static func clock(_ s: TimeInterval) -> String {
        let t = Int(s.rounded(.up))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Watches the calendar: a countdown when a meeting starts within 10 minutes, an alert (with Join) when it starts.
@MainActor
final class MeetingWatcher {
    private let store = EKEventStore()
    private weak var hub: IslandHub?
    private var timer: Foundation.Timer?
    private var announced = Set<String>()

    init(hub: IslandHub) { self.hub = hub }

    func start() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Once a minute is enough for "in N min"; the card itself ticks every second.
        timer = Foundation.Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    private func check() {
        guard let hub, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { hub?.setMeeting(nil); return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(10 * 60), calendars: nil)
        let next = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-60) && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }.first
        guard let e = next else { hub.setMeeting(nil); return }
        let join = Self.joinURL(e)
        let title = e.title ?? "Meeting"
        if e.startDate <= now.addingTimeInterval(5) {
            hub.setMeeting(nil)
            let key = (e.eventIdentifier ?? title) + "\(e.startDate.timeIntervalSince1970)"
            if announced.insert(key).inserted { hub.show(.init(kind: .meetingNow(title: title, joinURL: join), duration: 20)) }
        } else {
            hub.setMeeting((title, e.startDate, join))
            // Re-check right when it starts.
            let delay = e.startDate.timeIntervalSince(now)
            if delay < 30 { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() } }
        }
    }

    /// Zoom / Meet / Teams / Webex link from the event's URL, location or notes.
    nonisolated static func joinURL(_ e: EKEvent) -> URL? {
        if let u = e.url, isMeetingLink(u.absoluteString) { return u }
        let text = [e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        return findMeetingLink(in: text)
    }

    nonisolated static func findMeetingLink(in text: String) -> URL? {
        let pattern = #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com)[^\s<>"]*"#
        guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return URL(string: String(text[r]))
    }

    nonisolated static func isMeetingLink(_ s: String) -> Bool { findMeetingLink(in: s) != nil }
}

/// Files dropped on the notch, kept until dragged out, AirDropped or cleared (paths persist across restarts).
@MainActor
@Observable
final class FileShelf {
    private(set) var items: [URL] = [] {
        didSet { UserDefaults.standard.set(items.map(\.path), forKey: "island.shelf") }
    }

    init() {
        items = (UserDefaults.standard.stringArray(forKey: "island.shelf") ?? [])
            .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }
    func clear() { items = [] }

    func airDrop() {
        guard !items.isEmpty, let s = NSSharingService(named: .sendViaAirDrop) else { return }
        s.perform(withItems: items)
    }
}
