import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// `Sidekick -uiTest YES` (or `./build.sh uitest`): drives the real UI with synthesized keyboard/mouse events.
/// Dry-run mode: nothing is sent to Gemini and dictation never types into other apps. Exit code = failures.
@MainActor
enum UITest {
    static var failures = 0
    static func pass(_ n: String, _ d: String = "") { print("UI PASS  \(n)\(d.isEmpty ? "" : " — " + d)"); fflush(stdout) }
    static func fail(_ n: String, _ d: String) { failures += 1; print("UI FAIL  \(n) — \(d)"); fflush(stdout) }
    static func check(_ ok: Bool, _ n: String, _ d: String = "") { ok ? pass(n, d) : fail(n, d) }

    static func run(env: AppEnvironment) async {
        env.coordinator.silenced = true
        env.launch()
        env.coordinator.dryRun = true
        env.dictation.dryRun = true
        let savedTurn = env.coordinator.onTurnFinished
        env.coordinator.onTurnFinished = nil
        let mouseStart = NSEvent.mouseLocation
        try? await sleep(1.0)
        guard env.state.hotkeyInstalled else {
            fail("event tap", "not installed (Accessibility?)"); finish(env, savedTurn); return
        }
        let talk = env.settings.data.pushToTalk
        let usageBefore = env.usage.meter.today().inputTokens

        // 1) Push-to-talk through the real event tap
        await press(talk)
        try? await sleep(0.45)
        check(env.state.phase == .listening && env.state.bubbleVisible, "push-to-talk → listening", "\(env.state.phase)")
        check(env.coordinator.overlay.inkEnabled, "overlay accepts ink while held")
        await release(talk)
        try? await waitUntil(4) { env.state.reply.hasPrefix("dry run") || env.state.phase != .listening && env.state.phase != .transcribing }
        check(!env.coordinator.overlay.inkEnabled, "overlay click-through again after release")
        check(env.usage.meter.today().inputTokens == usageBefore, "dry run made no API call", env.state.reply)

        // 2) Releasing an extra modifier must not start push-to-talk
        await press(talk.union([.command]))
        await releaseOnly([.command])
        try? await sleep(0.45)
        check(env.state.phase != .listening, "⌘ release from \(talk.union([.command]).symbols) doesn't trigger", "\(env.state.phase)")
        await release(talk)
        try? await sleep(0.3)

        // 3) Esc cancels while listening
        await press(talk)
        try? await sleep(0.45)
        await key(kVK_Escape, [])
        try? await sleep(0.3)
        check(env.state.phase == .idle || {
            if case .message = env.state.phase { return true }; return false }(), "esc cancels listening", "\(env.state.phase)")
        await release(talk)
        try? await sleep(0.8)

        // 4) Ink: drag while holding the hotkey
        await press(talk)
        try? await sleep(0.45)
        let c = CGPoint(x: NSScreen.screens[0].frame.midX, y: NSScreen.screens[0].frame.midY)
        await drag(from: c, to: CGPoint(x: c.x + 120, y: c.y + 40))
        await release(talk)
        try? await sleep(0.6)
        check(env.coordinator.lastInkStrokeCount == 1, "ink stroke captured while holding", "\(env.coordinator.lastInkStrokeCount) strokes")
        try? await sleep(2.5)

        // 5) Dictation hold (dry run)
        let dictate = env.settings.data.dictateKeys
        await press(dictate)
        try? await sleep(0.45)
        check(env.state.dictation == .holding, "dictation hold → HUD", "\(env.state.dictation)")
        await release(dictate)
        try? await waitUntil(6) { env.state.dictation == .idle }
        check(env.state.dictation == .idle, "dictation finishes", "text=\(env.dictation.lastDryRunText ?? "(silence)")")
        // Level callback handed back: push-to-talk ring should still get levels after a quick dictation tap.
        await press(dictate); await release(dictate)
        try? await sleep(0.3)
        await press(talk); try? await sleep(0.8)
        let sawLevel = env.state.level > 0
        await release(talk)
        try? await sleep(1.5)
        check(sawLevel, "talk ring still gets mic levels after a dictation tap", "level=\(env.state.level)")

        // 6) Triple-tap always-on
        let ao = env.settings.data.alwaysOnKey
        for _ in 0..<3 { await press(ao); await release(ao); try? await sleep(0.08) }
        try? await sleep(0.4)
        check(env.alwaysOn.active, "triple-tap \(ao.symbols) → always-on")
        for _ in 0..<3 { await press(ao); await release(ao); try? await sleep(0.08) }
        try? await sleep(0.4)
        check(!env.alwaysOn.active, "triple-tap again → off")

        // 7) Home chord opens / closes the notch
        let home = env.settings.data.homeChord
        await key(home.keyCode, home.modifiers)
        try? await sleep(0.7)
        check(env.notch.ui.isOpen, "\(home.symbols) opens the notch chat")
        try? await sleep(0.6)
        check(env.notch.isTyping, "input is focused → panel stays open while typing")
        check(!env.notch.shouldAutoClose, "auto-close suppressed while typing")
        // Resize from a fixed start never compounds
        let start = env.notch.ui.targetSize
        env.notch.resize(by: CGSize(width: 100, height: 40), from: start)
        env.notch.resize(by: CGSize(width: 100, height: 40), from: start)
        check(env.notch.ui.expandedSize == CGSize(width: start.width + 100, height: start.height + 40), "edge resize doesn't compound", "\(env.notch.ui.expandedSize)")
        env.notch.resetSize()
        try? await sleep(0.5)
        await key(home.keyCode, home.modifiers)
        try? await sleep(0.8)
        check(!env.notch.ui.isOpen, "\(home.symbols) again closes it")

        // 8) Hover the notch → peek; leave → closes
        let notchRect = NotchGeometry.forScreen(NotchController.preferredScreen()).rect
        await moveMouse(to: CGPoint(x: notchRect.midX, y: NotchController.preferredScreen().frame.maxY - 2))
        try? await sleep(0.9)   // 0.4 s dwell + morph
        check(env.notch.ui.size == .peek, "hover the notch → peek", "\(env.notch.ui.size)")
        await moveMouse(to: c)
        try? await sleep(0.9)
        check(!env.notch.ui.isOpen, "leave → closes after grace")

        // 9) Pop-out / tuck back
        env.notch.popOut()
        try? await sleep(0.6)
        check(env.notch.ui.poppedOut && env.notch.popoutWindow?.isVisible == true, "pop-out window")
        env.notch.tuckBack()
        try? await sleep(0.6)
        check(!env.notch.ui.poppedOut, "tuck back into the notch")
        env.notch.close()
        try? await sleep(0.6)

        // 10) Teaching: the tutorial waits for a click on the Apple menu
        env.coordinator.tutorial()
        try? await sleep(1.0)
        let scr = NSScreen.screens[0]
        let apple = CGPoint(x: scr.frame.minX + 20, y: scr.frame.maxY - NSStatusBar.system.thickness / 2)
        await click(at: apple)
        try? await sleep(0.8)
        check(env.state.reply.hasPrefix("nice!"), "tutorial advances on the right click", "\"\(env.state.reply.prefix(50))\"")
        await key(kVK_Escape, [])   // close the Apple menu we opened
        try? await sleep(0.4)

        // 11) Typing into a text field + learning a correction
        await typingTest(env)

        // 12) Mic switch mid-recording
        await press(talk)
        try? await sleep(0.45)
        env.audio.simulateDeviceChange()
        try? await sleep(0.4)
        check(env.audio.isRunning, "capture survives an input-device change")
        await release(talk)
        try? await sleep(1.0)

        // 13) Voice by language (with this Mac's installed voices)
        let voices = VoiceSelector.installed()
        let hi = VoiceSelector.pick(for: "यह फाइंडर है", preferred: nil, voices: voices)
        let hiLang = voices.first { $0.id == hi }?.language ?? "none"
        hiLang.hasPrefix("hi") ? pass("hindi reply → hindi voice", hiLang) : print("UI INFO  no hindi voice installed (\(hiLang)) — install one in System Settings › Accessibility › Spoken Content")

        await moveMouse(to: CGPoint(x: mouseStart.x, y: mouseStart.y))
        finish(env, savedTurn)
    }

    static func finish(_ env: AppEnvironment, _ turnHook: ((ConversationTurn, String, TokenUsage?, Double) -> Void)?) {
        env.coordinator.onTurnFinished = turnHook
        env.coordinator.dryRun = false
        env.dictation.dryRun = false
        print("UI DONE failures=\(failures)"); fflush(stdout)
        exit(Int32(min(failures, 100)))
    }

    // MARK: Text field + correction learning (in our own window)

    static func typingTest(_ env: AppEnvironment) async {
        let win = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 420, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 420, height: 160))
        win.contentView = tv
        win.title = "sidekick ui test"
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(tv)
        try? await sleep(0.6)
        let inserter = TextInserter()
        let r = await inserter.insert("ask Clode about it")
        try? await sleep(0.4)
        check(tv.string.contains("ask Clode about it"), "text insertion into a focused field", "via \(r.map { "\($0.method)" } ?? "nil"): \"\(tv.string)\"")
        // The user fixes a word → the dictionary learns it.
        let watcher = CorrectionWatcher()
        var learned: (String, String)?
        watcher.onLearn = { learned = ($0, $1) }
        if let r { watcher.watch(r) }
        if let range = tv.string.range(of: "Clode") {
            tv.setSelectedRange(NSRange(range, in: tv.string))
            tv.insertText("Claude", replacementRange: NSRange(range, in: tv.string))
        }
        try? await waitUntil(4) { learned != nil }
        check(learned?.0 == "Clode" && learned?.1 == "Claude", "correction learned from an edit", "\(learned.map { "\($0.0)→\($0.1)" } ?? "nothing")")
        watcher.stop()
        win.orderOut(nil)
    }

    // MARK: Synthesized input

    static let keyFor: [(ModifierSet, Int, CGEventFlags)] = [
        (.control, kVK_Control, .maskControl), (.option, kVK_Option, .maskAlternate), (.command, kVK_Command, .maskCommand),
        (.shift, kVK_Shift, .maskShift), (.fn, kVK_Function, .maskSecondaryFn),
    ]
    static var held: CGEventFlags = []

    static func flagsEvent(_ code: Int) {
        let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(code), keyDown: true)
        e?.type = .flagsChanged
        e?.flags = held
        e?.post(tap: .cghidEventTap)
    }

    static func press(_ mods: ModifierSet) async {
        for (m, code, flag) in keyFor where mods.contains(m) && !held.contains(flag) {
            held.insert(flag)
            flagsEvent(code)
            try? await sleep(0.02)
        }
    }

    static func releaseOnly(_ mods: ModifierSet) async {
        for (m, code, flag) in keyFor.reversed() where mods.contains(m) && held.contains(flag) {
            held.remove(flag)
            flagsEvent(code)
            try? await sleep(0.02)
        }
    }

    static func release(_ mods: ModifierSet) async { await releaseOnly(mods.union([.command, .shift, .option, .control, .fn])) }

    static func key(_ code: Int, _ mods: ModifierSet) async {
        var flags: CGEventFlags = []
        for (m, _, f) in keyFor where mods.contains(m) { flags.insert(f) }
        let src = CGEventSource(stateID: .hidSystemState)
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)
        d?.flags = flags.union(held); u?.flags = flags.union(held)
        d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
        try? await sleep(0.05)
    }

    static func q(_ p: CGPoint) -> CGPoint { CoordinateMapper.quartz(fromAppKit: p, primaryHeight: NSScreen.screens[0].frame.height) }

    static func moveMouse(to p: CGPoint) async {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q(p), mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await sleep(0.05)
    }

    static func click(at p: CGPoint) async {
        await moveMouse(to: p)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: q(p), mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: q(p), mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await sleep(0.1)
    }

    static func drag(from a: CGPoint, to b: CGPoint) async {
        await moveMouse(to: a)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: q(a), mouseButton: .left)
        down?.flags = held
        down?.post(tap: .cghidEventTap)
        for i in 1...12 {
            let t = CGFloat(i) / 12
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: q(p), mouseButton: .left)
            e?.flags = held
            e?.post(tap: .cghidEventTap)
            try? await sleep(0.015)
        }
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: q(b), mouseButton: .left)
        up?.flags = held
        up?.post(tap: .cghidEventTap)
        try? await sleep(0.1)
    }

    static func sleep(_ s: Double) async throws { try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    static func waitUntil(_ timeout: Double, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try await sleep(0.05) }
    }
}
