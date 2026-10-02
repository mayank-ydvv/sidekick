import AppKit
import CoreGraphics

/// Global keyboard observer built on a CGEventTap.
/// - Modifier-only push-to-talk via `flagsChanged`.
/// - Consumes Esc only while `isSessionActive` returns true.
@MainActor
final class EventTapManager {
    enum Binding: Hashable { case talk, dictate, control }

    var onPushToTalk: ((HotkeyEvent) -> Void)?
    var onDictate: ((HotkeyEvent) -> Void)?
    /// Bare ⌃ presses (triple-tap toggles always-on voice).
    var onControl: ((HotkeyEvent) -> Void)?
    /// ⌃⌘A — open the Home panel.
    var onHome: (() -> Void)?
    /// Return true to consume the Esc key.
    var onEscape: (() -> Bool)?

    private var detectors: [Binding: HoldHotkeyDetector]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var holdTimers: [Binding: DispatchWorkItem] = [:]

    /// ⌃⌘A by default; rebindable.
    var homeChord: KeyChord = .home
    /// While recording a new shortcut in Settings, hotkeys don't fire.
    var paused = false

    init(pushToTalk: ModifierSet = [.control, .option], dictate: ModifierSet = [.fn, .control], alwaysOn: ModifierSet = [.control]) {
        detectors = [.talk: HoldHotkeyDetector(required: pushToTalk),
                     .dictate: HoldHotkeyDetector(required: dictate),
                     .control: HoldHotkeyDetector(required: alwaysOn)]
    }

    var isRunning: Bool { tap != nil }

    func updateBinding(_ b: Binding, _ mods: ModifierSet) {
        detectors[b] = HoldHotkeyDetector(required: mods)
    }

    func binding(_ b: Binding) -> ModifierSet { detectors[b]?.required ?? [] }

    /// Requires Accessibility (active tap so Esc can be consumed). Returns false if it couldn't install.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                // Tap callbacks are delivered on the main run loop (we add the source there).
                let consume = MainActor.assumeIsolated { mgr.handle(type: type, event: event) }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkeys.error("CGEvent.tapCreate failed (Accessibility not granted?)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        self.source = src
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotkeys.info("event tap installed")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Returns true if the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if paused, type == .flagsChanged || type == .keyDown { return false }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events were lost while disabled: feed the current modifier state so held/released keys resync.
            let mods = ModifierSet(cgFlags: CGEventSource.flagsState(.combinedSessionState))
            for b in detectors.keys {
                if let e = detectors[b]!.flagsChanged(mods, at: now) { emit(e, b) }
            }
            return false
        case .flagsChanged:
            let mods = ModifierSet(cgFlags: event.flags)
            for b in detectors.keys {
                if let e = detectors[b]!.flagsChanged(mods, at: now) { emit(e, b) }
            }
            return false
        case .keyDown:
            for b in detectors.keys {
                if let e = detectors[b]!.keyDown(at: now) { emit(e, b) }
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if Int(keyCode) == homeChord.keyCode, ModifierSet(cgFlags: event.flags) == homeChord.modifiers,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onHome?()
                return true
            }
            if keyCode == 53 /* kVK_Escape */, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                return onEscape?() ?? false
            }
            return false
        default:
            return false
        }
    }

    private func emit(_ e: HotkeyEvent, _ b: Binding) {
        switch e {
        case .armed:
            holdTimers[b]?.cancel()
            let threshold = detectors[b]?.holdThreshold ?? 0.15
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let ev = self.detectors[b]?.tick(at: ProcessInfo.processInfo.systemUptime) {
                    self.deliver(ev, b)
                }
            }
            holdTimers[b] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: item)
        case .cancelled, .ended, .tap:
            holdTimers[b]?.cancel()
            holdTimers[b] = nil
        case .began:
            break
        }
        deliver(e, b)
    }

    private func deliver(_ e: HotkeyEvent, _ b: Binding) {
        switch b {
        case .talk: onPushToTalk?(e)
        case .dictate: onDictate?(e)
        case .control: onControl?(e)
        }
    }
}
