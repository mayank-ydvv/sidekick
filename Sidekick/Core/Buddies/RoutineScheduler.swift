import AppKit
import Network

/// Runs buddy routines on schedule using a single timer for the earliest due routine (min-heap).
/// Waits for wake + network; offline misses don't count as failures; pauses a routine after 3 real failures.
@MainActor
final class RoutineScheduler {
    private let store: BuddyStore
    private var heap = MinHeap<(Date, Int64)> { $0.0 < $1.0 }
    private var timer: Timer?
    private let monitor = NWPathMonitor()
    private var online = true
    private var running: Set<Int64> = []
    /// Runs a routine headlessly; returns (succeeded, wasOffline).
    var execute: ((RoutineRecord, BuddyRecord) async -> (Bool, Bool))?

    static let maxFailures = 3

    init(store: BuddyStore) { self.store = store }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let was = self?.online ?? true
                self?.online = path.status == .satisfied
                if !was, path.status == .satisfied { self?.reschedule() }   // back online: catch up
            }
        }
        monitor.start(queue: DispatchQueue(label: "sidekick.net"))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        reschedule()
    }

    /// Rebuilds the heap from the DB (call after routines change). O(n log n), n is tiny.
    func reschedule() {
        heap = MinHeap { $0.0 < $1.0 }
        for r in store.routines where r.enabled {
            guard let id = r.id else { continue }
            let next = r.nextRunAt ?? Schedule.parse(r.schedule)?.next(after: Date()) ?? Date.distantFuture
            heap.push((next, id))
        }
        armTimer()
    }

    private func armTimer() {
        timer?.invalidate()
        guard let (when, _) = heap.peek else { return }
        let delay = max(1, when.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: min(delay, 3600), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer?.tolerance = 5
    }

    private func fire() {
        let now = Date()
        while let (when, id) = heap.peek, when <= now {
            heap.pop()
            run(id)
        }
        armTimer()
    }

    func runNow(_ r: RoutineRecord) { if let id = r.id { run(id, manual: true) } }

    private func run(_ id: Int64, manual: Bool = false) {
        guard !running.contains(id), let r = store.routines.first(where: { $0.id == id }), r.enabled || manual,
              let b = store.buddy(r.buddyId), !b.archived else { return }
        running.insert(id)
        Task {
            var rec = r
            if !online {
                rec.nextRunAt = Date().addingTimeInterval(15 * 60)   // offline: retry soon, not a failure
            } else {
                let (ok, deferred) = await execute?(r, b) ?? (false, false)
                if ok { rec.failCount = 0 }
                else if !deferred {
                    rec.failCount += 1
                    if rec.failCount >= Self.maxFailures { rec.enabled = false }
                }
                // Deferred (offline / quiet): retry in 15 min instead of waiting for the next slot.
                rec.nextRunAt = (!ok && deferred) ? Date().addingTimeInterval(15 * 60) : Schedule.parse(r.schedule)?.next(after: Date())
            }
            await store.saveRoutine(rec)
            running.remove(id)
            reschedule()
        }
    }
}
