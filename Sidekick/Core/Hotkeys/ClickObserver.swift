import AppKit

/// Observes the user's left clicks anywhere, only while active.
/// NSEvent global monitors for mouse events need no extra permission and cost nothing when removed.
@MainActor
final class ClickObserver {
    private var monitors: [Any] = []
    private var handler: ((CGPoint) -> Void)?
    private var armedAt: TimeInterval = 0

    var isActive: Bool { !monitors.isEmpty }

    func start(_ onClick: @escaping (CGPoint) -> Void) {
        stop()
        handler = onClick
        armedAt = ProcessInfo.processInfo.systemUptime
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.fire() }
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        handler = nil
    }

    private func fire() {
        // Ignore clicks that land within 250 ms of arming (e.g. the click that triggered the step).
        guard ProcessInfo.processInfo.systemUptime - armedAt > 0.25 else { return }
        handler?(NSEvent.mouseLocation)
    }
}
