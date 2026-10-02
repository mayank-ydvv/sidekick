import AppKit
import SwiftUI

/// Settings → shortcuts: record new hotkeys (modifier-only holds, a triple-tap key, and the Home chord).
struct ShortcutsTab: View {
    let env: AppEnvironment
    @State private var recording: HotkeyValidator.Role?
    @State private var held: ModifierSet = []
    @State private var peak: ModifierSet = []
    @State private var error: String?
    @State private var monitor: Any?

    var body: some View {
        let d = env.settings.data
        Form {
            Section {
                row(.talk, "hold to ask", d.pushToTalk.symbols)
                row(.dictate, "hold to dictate · double-tap for hands-free", d.dictateKeys.symbols)
                row(.alwaysOn, "triple-tap for always-on listening", d.alwaysOnKey.symbols)
                row(.home, "open the notch chat", d.homeChord.symbols)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                ForEach(HotkeyValidator.warnings(d.pushToTalk, role: .talk, voiceOverOn: NSWorkspace.shared.isVoiceOverEnabled)
                        + HotkeyValidator.warnings(d.dictateKeys, role: .dictate, voiceOverOn: false), id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("esc always stops sidekick while it's busy. changes apply right away.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("reset to defaults") {
                    env.settings.data.pushToTalk = [.control, .option]
                    env.settings.data.dictateKeys = [.fn, .control]
                    env.settings.data.alwaysOnKey = [.control]
                    env.settings.data.homeChord = .home
                    env.applyHotkeys()
                    error = nil
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stopRecording)
    }

    private func row(_ role: HotkeyValidator.Role, _ caption: String, _ current: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(role.rawValue)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if recording == role {
                Text(held.isEmpty ? (role == .home ? "press the shortcut…" : "press and release keys…") : held.symbols)
                    .font(.system(.body, design: .monospaced)).foregroundStyle(Color.accentColor)
                Button("cancel") { stopRecording() }
            } else {
                Text(current).font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                Button("change") { startRecording(role) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func startRecording(_ role: HotkeyValidator.Role) {
        stopRecording()
        recording = role
        error = nil
        held = []; peak = []
        env.hotkeys.paused = true   // so pressing the old combo doesn't trigger sidekick
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in
            MainActor.assumeIsolated { handle(e, role: role) }
            return nil   // swallow while recording
        }
    }

    private func handle(_ e: NSEvent, role: HotkeyValidator.Role) {
        let mods = ModifierSet(cgFlags: CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue)))
        if e.type == .keyDown {
            if e.keyCode == 53 { return stopRecording() }   // esc cancels
            guard role == .home else { return }
            let chord = KeyChord(keyCode: Int(e.keyCode), modifiers: mods)
            if let p = HotkeyValidator.chordProblem(chord) { error = p; return }
            env.settings.data.homeChord = chord
            return finish()
        }
        guard role != .home else { held = mods; return }
        held = mods
        if mods.isSuperset(of: peak) { peak = mods }
        guard mods.isEmpty, !peak.isEmpty else { return }   // all keys released → commit the peak
        let d = env.settings.data
        let others: [HotkeyValidator.Role: ModifierSet] = [.talk: d.pushToTalk, .dictate: d.dictateKeys, .alwaysOn: d.alwaysOnKey]
        if let p = HotkeyValidator.problem(peak, role: role, others: others) {
            error = p
            peak = []
            return
        }
        switch role {
        case .talk: env.settings.data.pushToTalk = peak
        case .dictate: env.settings.data.dictateKeys = peak
        case .alwaysOn: env.settings.data.alwaysOnKey = peak
        case .home: break
        }
        finish()
    }

    private func finish() {
        env.applyHotkeys()
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        held = []
        env.hotkeys.paused = false
    }
}
