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

    enum MediaKey { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }
    /// Volume / brightness keys (key-down and repeats). Return true to handle it instead of macOS.
    /// `fine` = ⌥⇧ held (quarter steps, like macOS).
    var onMediaKey: ((MediaKey, _ fine: Bool) -> Bool)?

    private var detectors: [Binding: HoldHotkeyDetector]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var holdTimers: [Binding: DispatchWorkItem] = [:]
    private var handledMediaDown = Set<MediaKey>()

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
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << Self.systemDefined)
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

    /// NX_SYSDEFINED: media/brightness keys arrive as system-defined events (subtype 8).
    static let systemDefined: UInt32 = 14

    /// Decodes a volume/brightness key from a system-defined event. Returns (key, isDown).
    nonisolated static func mediaKey(subtype: Int16, data1: Int) -> (EventTapManager.MediaKey, Bool)? {
        guard subtype == 8 else { return nil }
        let code = (data1 & 0xFFFF0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        let down = state == 0xA
        let key: EventTapManager.MediaKey
        switch code {
        case 0: key = .volumeUp          // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown        // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute              // NX_KEYTYPE_MUTE
        case 2: key = .brightnessUp      // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown    // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: return nil
        }
        return (key, down)
    }

    /// Returns true if the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type.rawValue == Self.systemDefined {
            guard !paused, let onMediaKey, let ns = NSEvent(cgEvent: event),
                  let (key, down) = Self.mediaKey(subtype: ns.subtype.rawValue, data1: ns.data1) else { return false }
            let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
            // Swallow the key-up too when we handled the key-down (so macOS never shows its own pop-up).
            if !down { return handledMediaDown.remove(key) != nil }
            let handled = onMediaKey(key, fine)
            if handled { handledMediaDown.insert(key) }
            return handled
        }
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
