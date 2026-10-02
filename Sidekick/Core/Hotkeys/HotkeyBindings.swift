import CoreGraphics
import Foundation

/// Modifier keys we care about, independent of CGEventFlags bit layout.
struct ModifierSet: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int
    static let control = ModifierSet(rawValue: 1 << 0)
    static let option  = ModifierSet(rawValue: 1 << 1)
    static let command = ModifierSet(rawValue: 1 << 2)
    static let shift   = ModifierSet(rawValue: 1 << 3)
    static let fn      = ModifierSet(rawValue: 1 << 4)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(cgFlags f: CGEventFlags) {
        var s: ModifierSet = []
        if f.contains(.maskControl) { s.insert(.control) }
        if f.contains(.maskAlternate) { s.insert(.option) }
        if f.contains(.maskCommand) { s.insert(.command) }
        if f.contains(.maskShift) { s.insert(.shift) }
        if f.contains(.maskSecondaryFn) { s.insert(.fn) }
        self = s
    }

    /// "control and option" — for speaking.
    var spoken: String {
        var parts: [String] = []
        if contains(.fn) { parts.append("fn") }
        if contains(.control) { parts.append("control") }
        if contains(.option) { parts.append("option") }
        if contains(.shift) { parts.append("shift") }
        if contains(.command) { parts.append("command") }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? ""
    }

    /// "Control + Option" — for buttons and labels.
    var titled: String {
        var parts: [String] = []
        if contains(.fn) { parts.append("Fn") }
        if contains(.control) { parts.append("Control") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Command") }
        return parts.joined(separator: " + ")
    }

    var symbols: String {
        var out = ""
        if contains(.fn) { out += "fn " }
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

enum HotkeyEvent: Equatable {
    /// Exact combo pressed — start capturing silently (pre-roll).
    case armed
    /// Held past the threshold — show UI.
    case began
    /// Released after `began`.
    case ended
    /// Interrupted before `began` (another key/modifier pressed) — discard.
    case cancelled
    /// Released cleanly before `began` — a quick tap (used for double-tap gestures).
    case tap
}

/// Pure state machine for a modifier-only "hold" hotkey.
/// Arms on an exact modifier match, becomes active after `holdThreshold`,
/// cancels if another key is pressed while armed (so ⌃⌥→ shortcuts keep working).
struct HoldHotkeyDetector {
    enum State: Equatable { case idle, armed(since: TimeInterval), active }

    var required: ModifierSet
    var holdThreshold: TimeInterval
    private(set) var state: State = .idle
    /// Previous modifier state, so releasing ⌘ from ⌃⌥⌘ doesn't count as pressing ⌃⌥.
    private var lastMods: ModifierSet = []

    init(required: ModifierSet, holdThreshold: TimeInterval = 0.15) {
        self.required = required
        self.holdThreshold = holdThreshold
    }

    mutating func flagsChanged(_ mods: ModifierSet, at t: TimeInterval) -> HotkeyEvent? {
        let previous = lastMods
        lastMods = mods
        switch state {
        case .idle:
            // Only a press that builds up to the combo arms it (previous was a strict subset).
            if mods == required, required.isSuperset(of: previous), previous != required {
                state = .armed(since: t)
                return .armed
            }
        case .armed:
            if mods != required {
                state = .idle
                // Releasing keys (subset) is a tap; adding a different modifier cancels.
                return required.isSuperset(of: mods) ? .tap : .cancelled
            }
        case .active:
            if !mods.isSuperset(of: required) {
                state = .idle
                return .ended
            }
        }
        return nil
    }

    /// A non-modifier key was pressed.
    mutating func keyDown(at t: TimeInterval) -> HotkeyEvent? {
        if case .armed = state {
            state = .idle
            return .cancelled
        }
        return nil
    }

    /// Called by a timer after the threshold elapses (or any time; it checks the clock).
    mutating func tick(at t: TimeInterval) -> HotkeyEvent? {
        if case .armed(let since) = state, t - since >= holdThreshold {
            state = .active
            return .began
        }
        return nil
    }

    mutating func reset() { state = .idle }
}

/// Counts quick taps of the same hotkey: a tap within `window` of the previous one extends the run.
struct TapCounter {
    var window: TimeInterval = 0.3
    private(set) var count = 0
    private var last: TimeInterval = -.infinity

    /// Records a tap; returns how many consecutive quick taps have happened (1, 2, 3…).
    mutating func tap(at t: TimeInterval) -> Int {
        count = (t - last <= window) ? count + 1 : 1
        last = t
        return count
    }

    mutating func reset() { count = 0; last = -.infinity }
}
