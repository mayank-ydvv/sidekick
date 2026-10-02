import AppKit
import Carbon.HIToolbox

/// A key + modifiers chord (e.g. ⌃⌘A for Home).
struct KeyChord: Codable, Equatable, Sendable {
    var keyCode: Int
    var modifiers: ModifierSet

    static let home = KeyChord(keyCode: kVK_ANSI_A, modifiers: [.control, .command])

    var symbols: String { modifiers.symbols + KeyChord.keyName(keyCode) }

    static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            kVK_Space: "space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "esc", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let n = names[code] { return n }
        if let k = AXTree.keyCodes.first(where: { Int($0.value) == code })?.key, k.count == 1 { return k.uppercased() }
        return "key \(code)"
    }
}

/// Rules for hotkeys the user picks. Pure, so it's unit-tested.
enum HotkeyValidator {
    enum Role: String { case talk = "push to talk", dictate = "dictation", alwaysOn = "always-on toggle", home = "home panel" }

    /// Returns a blocking problem, or nil if the binding is usable.
    static func problem(_ mods: ModifierSet, role: Role, others: [Role: ModifierSet]) -> String? {
        let count = [ModifierSet.control, .option, .command, .shift, .fn].filter { mods.contains($0) }.count
        switch role {
        case .alwaysOn:
            if count != 1 { return "pick a single key to triple-tap" }
        default:
            if count < 2 { return "use at least two modifier keys, so normal typing never triggers it" }
            if mods == [.command, .shift] || mods == [.command, .option] { return "\(mods.symbols) is used by too many app shortcuts" }
        }
        for (other, m) in others where other != role && m == mods && other != .alwaysOn {
            return "already used for \(other.rawValue)"
        }
        return nil
    }

    /// Soft warnings shown under the picker (not blocking).
    static func warnings(_ mods: ModifierSet, role: Role, voiceOverOn: Bool) -> [String] {
        var w: [String] = []
        if mods == [.control, .option], voiceOverOn { w.append("⌃⌥ is VoiceOver's key — with VoiceOver on, pick something else") }
        if mods.contains(.fn) { w.append("many external keyboards don't have a fn key") }
        return w
    }

    static func chordProblem(_ c: KeyChord) -> String? {
        if c.modifiers.subtracting([.shift]).isEmpty { return "add ⌃, ⌥ or ⌘ so it doesn't clash with typing" }
        if c.modifiers == [.command] { return "⌘ alone clashes with app shortcuts — add ⌃ or ⌥" }
        return nil
    }
}
