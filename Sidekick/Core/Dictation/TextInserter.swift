import AppKit
import ApplicationServices

/// Inserts text at the cursor in any app: Accessibility first, clipboard paste as fallback.
@MainActor
final class TextInserter {
    struct Result {
        enum Method { case accessibility, paste }
        var method: Method
        /// For correction learning (nil when the field can't be read).
        var element: AXUIElement?
        var valueAfter: String?
        var insertedRange: NSRange?
    }

    /// Apps where AX text setting is known to be unreliable → paste directly.
    static func prefersPaste(_ app: NSRunningApplication?) -> Bool {
        guard let app, let url = app.bundleURL else { return false }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            return true
        }
        let chromiumish = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]
        return chromiumish.contains(app.bundleIdentifier ?? "")
    }

    func insert(_ raw: String) async -> Result? {
        guard !raw.isEmpty else { return nil }
        let app = NSWorkspace.shared.frontmostApplication
        let element = Self.focusedElement()
        var text = raw

        if let element {
            let before = Self.value(element)
            let range = Self.selectedRange(element)
            // Add a space when continuing right after a word.
            if let before, let range, range.location > 0, range.location <= (before as NSString).length {
                let prev = (before as NSString).character(at: range.location - 1)
                if let sc = Unicode.Scalar(prev), !CharacterSet.whitespacesAndNewlines.contains(sc),
                   let first = text.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) {
                    text = " " + text
                }
            }
            if !Self.prefersPaste(app), let before, let range {
                let ok = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
                if ok, let after = Self.value(element), after != before {
                    return Result(method: .accessibility, element: element, valueAfter: after,
                                  insertedRange: NSRange(location: range.location, length: (text as NSString).length))
                }
            }
        }

        await paste(text)
        // Best effort: find what we pasted so corrections can still be learned.
        try? await Task.sleep(nanoseconds: 150_000_000)
        if let element, let after = Self.value(element) {
            let r = (after as NSString).range(of: text, options: .backwards)
            if r.location != NSNotFound {
                return Result(method: .paste, element: element, valueAfter: after, insertedRange: r)
            }
        }
        return Result(method: .paste, element: nil, valueAfter: nil, insertedRange: nil)
    }

    /// Saves the clipboard, pastes, then restores it after 300 ms.
    private func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        // A still-held ⌃/⌥ (from the dictation or talk hotkey) would turn ⌘V into another shortcut.
        await ComputerUse.waitForModifiersReleased()
        let src = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = []   // see keystroke(): never leave ⌘ "held"
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard pb.changeCount == ourChange else { return }   // user copied something meanwhile
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, v) in dict { item.setData(v, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    // MARK: AX helpers

    /// What the user is writing right now: the focused text field's text and their selection (never secure fields).
    struct FieldSnapshot: Sendable, Equatable {
        var text: String
        var selected: String
        /// The app the user was writing in — replacing only happens if it's still in front.
        var pid: pid_t = 0
    }

    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func focusedField() -> FieldSnapshot? {
        guard let el = focusedElement() else { return nil }
        var role: CFTypeRef?, sub: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
        guard editableRoles.contains(role as? String ?? ""), (sub as? String) != "AXSecureTextField",
              let text = value(el), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var sel: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel)
        return FieldSnapshot(text: String(text.prefix(4000)), selected: String(((sel as? String) ?? "").prefix(4000)),
                             pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    /// Replaces what the user wrote with `text`: their selection if they selected something, otherwise the whole
    /// focused field. Uses Accessibility where it works; in Chromium/Electron apps (Chrome, the Claude app, Slack…)
    /// it selects the field's contents with ⌘A and pastes. Returns false if there's no editable field.
    func replace(with text: String, expectedApp: pid_t? = nil) async -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        // The user switched apps while we were thinking: never select-and-paste into something else.
        if let expectedApp, expectedApp != 0, front?.processIdentifier != expectedApp { return false }
        guard let el = Self.focusedElement() else {
            // Chromium/Electron field we still can't see: the caret is in the box the user was writing in, so
            // select its text and paste over it (never insert next to it).
            guard Self.prefersPaste(front) else { return false }
            await Self.keystroke(0, .maskCommand)
            try? await Task.sleep(nanoseconds: 60_000_000)
            await paste(text)
            return true
        }
        var role: CFTypeRef?, sub: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
        guard Self.editableRoles.contains(role as? String ?? ""), (sub as? String) != "AXSecureTextField" else { return false }
        let app = NSWorkspace.shared.frontmostApplication
        let hasSelection = (Self.selectedRange(el)?.length ?? 0) > 0
        if !Self.prefersPaste(app) {
            if !hasSelection, let len = Self.value(el).map({ ($0 as NSString).length }) {
                var r = CFRange(location: 0, length: len)
                if let range = AXValueCreate(.cfRange, &r) {
                    AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, range)
                }
            }
            if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
               Self.value(el)?.contains(text) == true { return true }
            if !hasSelection, AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success,
               Self.value(el) == text { return true }
        }
        // Chromium/Electron fields ignore AX writes: select the field's text (unless the user selected some) and paste.
        if !hasSelection { await Self.keystroke(0, .maskCommand) }   // ⌘A
        try? await Task.sleep(nanoseconds: 60_000_000)
        await paste(text)
        return true
    }

    static func keystroke(_ key: CGKeyCode, _ flags: CGEventFlags) async {
        await ComputerUse.waitForModifiersReleased()
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = []   // release with no modifiers held, or macOS keeps thinking ⌘/⇧ is down (stuck capitals, stalls)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func focusedElement() -> AXUIElement? {
        if let el = systemFocused() { return el }
        // Chromium/Electron apps (Chrome, the Claude app, Slack, VS Code…) only build their accessibility tree when
        // asked: switch it on for the frontmost app, then ask again.
        guard let app = NSWorkspace.shared.frontmostApplication, prefersPaste(app) else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let el = systemFocused() { return el }
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &v) == .success,
           let v, CFGetTypeID(v) == AXUIElementGetTypeID() { return (v as! AXUIElement) }
        return nil
    }

    private static func systemFocused() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }
}

/// Watches a field for ~20 s after we insert text and learns small corrections the user makes.
@MainActor
final class CorrectionWatcher {
    private var observer: AXObserver?
    private var element: AXUIElement?
    private var baseline = ""
    private var range = NSRange()
    private var debounce: DispatchWorkItem?
    private var expiry: DispatchWorkItem?
    var onLearn: ((String, String) -> Void)?

    func watch(_ r: TextInserter.Result) {
        stop()
        guard let el = r.element, let after = r.valueAfter, let range = r.insertedRange else { return }
        element = el
        baseline = after
        self.range = range
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<CorrectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.changed() }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        let exp = DispatchWorkItem { [weak self] in self?.stop() }
        expiry = exp
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: exp)
    }

    private func changed() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func check() {
        guard let el = element, let now = TextInserter.value(el) else { return }
        if let (wrong, right) = CorrectionLearner.learn(before: baseline, after: now, inserted: range) {
            Log.app.info("learned a dictionary correction")
            onLearn?(wrong, right)
            stop()
        }
    }

    func stop() {
        debounce?.cancel()
        expiry?.cancel()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        element = nil
    }
}
