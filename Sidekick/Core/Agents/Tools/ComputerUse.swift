import AppKit
import ApplicationServices

/// Computer use: prefer Accessibility actions (no cursor movement, works in background windows);
/// fall back to synthesized events with a visible "Sidekick is controlling…" banner (Esc aborts).
final class ComputerUse: @unchecked Sendable {
    static let shared = ComputerUse()
    private let lock = NSLock()
    private var refs: [AXUIElement] = []
    private var mapper: CoordinateMapper?

    static let all: [AgentTool] = [read, click, type, key, menu]

    /// Asked once per agent run before the first ui_* action.
    static func isComputerUse(_ name: String) -> Bool { name.hasPrefix("ui_") }

    private func store(_ r: [AXUIElement], _ m: CoordinateMapper?) {
        lock.lock(); refs = r; mapper = m; lock.unlock()
    }
    private func ref(_ id: Int) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return refs.indices.contains(id) ? refs[id] : nil
    }
    private var currentMapper: CoordinateMapper? { lock.lock(); defer { lock.unlock() }; return mapper }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    // MARK: Tools

    static let read = AgentTool(
        name: "ui_read",
        description: "Look at the frontmost app: returns a screenshot plus a numbered list of its UI elements with positions (y,x in 0–1000). Call this before clicking or typing, and again after actions to verify.",
        parameters: Schema.object([:]),
        requiresConfirmation: { _, _ in false },
        run: { _, _ in
            guard let app = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else { return .error("no frontmost app") }
            let shot = try? await ScreenCapturer().capture(readBrowserURL: false)
            let snap = AXTree.snapshot(pid: app.processIdentifier, primaryHeight: primaryHeight)
            shared.store(snap.refs, shot?.mapper)
            let text = "app: \(app.localizedName ?? "?")\n" + AXTree.format(snap.nodes, mapper: shot?.mapper, menus: snap.menus)
            return ToolResult(text: text, image: shot?.jpeg)
        })

    static let click = AgentTool(
        name: "ui_click",
        description: "Click a UI element by its [id] from ui_read (preferred), or at y,x (0–1000 on the last screenshot).",
        parameters: Schema.object(["id": Schema.integer("Element id from ui_read"),
                                   "y": Schema.integer("0–1000"), "x": Schema.integer("0–1000")]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            if let id = args["id"] as? Int, let el = shared.ref(id) {
                if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return ToolResult(text: "pressed [\(id)]") }
                if let f = AXTree.frame(el, primaryHeight: primaryHeight) {
                    await synthClick(CGPoint(x: f.midX, y: f.midY))
                    return ToolResult(text: "clicked [\(id)] (mouse)")
                }
                return .error("couldn't press [\(id)]")
            }
            guard let y = args["y"] as? Int, let x = args["x"] as? Int, let m = shared.currentMapper else {
                return .error("give an element id, or y and x after ui_read")
            }
            await synthClick(m.screenPoint(normY: Double(y), normX: Double(x)))
            return ToolResult(text: "clicked at y=\(y) x=\(x)")
        })

    static let type = AgentTool(
        name: "ui_type",
        description: "Type text into element [id] (or the focused field). Never use for passwords, card numbers or codes.",
        parameters: Schema.object(["text": Schema.string("Text to type"), "id": Schema.integer("Element id (optional)"),
                                   "submit": Schema.string("\"true\" to press Return afterwards")], required: ["text"]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            guard let raw = args["text"] as? String else { return .error("missing text") }
            if looksSensitive(raw) { return .error("i don't type passwords, card numbers or codes") }
            let text = normalCase(raw, request: ctx.task)
            var target = (args["id"] as? Int).flatMap { shared.ref($0) }
            if let t = target { AXUIElementSetAttributeValue(t, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            if target == nil { target = await MainActor.run { TextInserter.focusedElement() } }
            if let t = target, AXTree.string(t, kAXSubroleAttribute) == "AXSecureTextField" {
                return .error("that's a password field — please type it yourself")
            }
            var done = false
            if let t = target {
                let before = AXTree.string(t, kAXValueAttribute)
                if AXUIElementSetAttributeValue(t, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
                   AXTree.string(t, kAXValueAttribute) != before { done = true }
                else if AXUIElementSetAttributeValue(t, kAXValueAttribute as CFString, text as CFString) == .success,
                        AXTree.string(t, kAXValueAttribute) == text { done = true }
            }
            if !done { await synthType(text) }
            if (args["submit"] as? String)?.lowercased() == "true" || args["submit"] as? Bool == true {
                await synthKey(36, [])
            }
            return ToolResult(text: "typed \(text.count) characters")
        })

    static let key = AgentTool(
        name: "ui_key",
        description: "Press a key or shortcut in the frontmost app, e.g. \"return\", \"cmd+l\", \"cmd+shift+n\", \"down\".",
        parameters: Schema.object(["combo": Schema.string("Key combo")], required: ["combo"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard let s = args["combo"] as? String, let (code, flags) = AXTree.keyCombo(s) else { return .error("unknown key") }
            await synthKey(code, flags)
            return ToolResult(text: "pressed \(s)")
        })

    static let menu = AgentTool(
        name: "ui_menu",
        description: "Choose a menu item in the frontmost app by path, e.g. \"File > New Folder\".",
        parameters: Schema.object(["path": Schema.string("Menu path")], required: ["path"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard let path = args["path"] as? String else { return .error("missing path") }
            guard let app = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else { return .error("no app") }
            let titles = AXTree.menuPath(path)
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            guard var cur = AXTree.element(ax, kAXMenuBarAttribute) else { return .error("no menu bar") }
            for (i, t) in titles.enumerated() {
                guard let next = child(of: cur, titled: t) else { return .error("couldn't find \"\(t)\" in the menu") }
                if i == titles.count - 1 {
                    return AXUIElementPerformAction(next, kAXPressAction as CFString) == .success
                        ? ToolResult(text: "chose \(path)") : .error("couldn't choose \(path)")
                }
                // Descend: menu bar item → its AXMenu → items.
                cur = firstChild(next) ?? next
            }
            return .error("empty path")
        })

    // MARK: Helpers

    static func child(of el: AXUIElement, titled t: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success, let kids = v as? [AXUIElement] else { return nil }
        let want = t.lowercased().replacingOccurrences(of: "…", with: "...")
        return kids.first { (AXTree.string($0, kAXTitleAttribute) ?? "").lowercased().replacingOccurrences(of: "…", with: "...") == want }
            ?? kids.first { (AXTree.string($0, kAXTitleAttribute) ?? "").lowercased().hasPrefix(want) }
    }

    static func firstChild(_ el: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return nil }
        return (v as? [AXUIElement])?.first
    }

    static func looksSensitive(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber)
        if digits.count >= 12, Double(digits.count) / Double(max(1, s.count)) > 0.6 { return true }   // card / account numbers
        if (6...8).contains(s.count), s.allSatisfy(\.isNumber) { return true }                        // OTP-like codes
        return false
    }

    static func synthClick(_ p: CGPoint) async {
        await ControlBanner.shared.pulse()
        let q = CoordinateMapper.quartz(fromAppKit: p, primaryHeight: primaryHeight)
        let original = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
        // Put the user's cursor back where it was.
        if let original { try? await Task.sleep(nanoseconds: 30_000_000); CGWarpMouseCursorPosition(original) }
    }

    /// Types text one character per event from a private event source with no modifier flags, so a held key
    /// (Shift, Caps Lock, or ⌃⌥ still down from push-to-talk) can never turn it into capitals or shortcuts, and apps
    /// that read only the first character of a multi-character event still get every letter.
    static func synthType(_ text: String) async {
        await ControlBanner.shared.pulse()
        await waitForModifiersReleased()
        let src = CGEventSource(stateID: .privateState)
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            for e in [down, up] {
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    /// Waits (up to 1.5 s) until the user lets go of ⌘ ⌃ ⌥ ⇧ — typing while they're held produces shortcuts or capitals.
    static func waitForModifiersReleased() async {
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<30 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The model sometimes writes "RAVI SHARMA" or "HEY". Unless the user asked for those capitals, type them
    /// normally: short names/phrases get Title Case ("Ravi Sharma", "Hey"), longer text gets sentence case.
    nonisolated static func normalCase(_ text: String, request: String) -> String {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 2, letters.allSatisfy({ $0.isUppercase || !$0.isCased }), letters.contains(where: \.isCased) else { return text }
        // Keep capitals the user typed/said themselves ("type NASA", "send OK").
        let asked = request.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { !$0.isEmpty }
        if !words.isEmpty, words.allSatisfy({ w in asked.contains(w) }) { return text }
        if words.count <= 4 {
            return text.lowercased().split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        var out = ""
        var capNext = true
        for ch in text.lowercased() {
            if capNext, ch.isLetter { out += ch.uppercased(); capNext = false } else { out.append(ch) }
            if ".!?".contains(ch) { capNext = true }
        }
        return out.replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)
    }

    static func synthKey(_ code: CGKeyCode, _ flags: CGEventFlags) async {
        await ControlBanner.shared.pulse()
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = []   // release with no modifiers held, or macOS keeps thinking ⌘/⇧ is down (stuck capitals, stalls)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in self {
            cur.append(ch)
            if cur.count == n { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Red pill under the notch while Sidekick drives the mouse/keyboard. Esc aborts the agent.
@MainActor
final class ControlBanner {
    static let shared = ControlBanner()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func pulse() {
        show()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func show() {
        if panel == nil {
            let size = CGSize(width: 300, height: 30)
            let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.sharingType = DebugFlags.capturable ? .readOnly : .none
            let label = NSTextField(labelWithString: "  sidekick is controlling your mac · esc to stop  ")
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
            label.layer?.cornerRadius = 15
            label.frame = CGRect(origin: .zero, size: size)
            p.contentView = label
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - 150, y: screen.visibleFrame.maxY - 40))
        panel.orderFrontRegardless()
    }
}
