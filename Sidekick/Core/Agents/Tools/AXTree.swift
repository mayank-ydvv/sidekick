import AppKit
import ApplicationServices

/// A flattened, model-friendly snapshot of the frontmost window's actionable UI.
struct AXNode: Equatable, Sendable {
    var id: Int
    var role: String
    var title: String
    /// Global AppKit frame.
    var frame: CGRect
}

enum AXTree {
    static let maxNodes = 200
    static let maxVisited = 2500

    static let interesting: Set<String> = AXInspector.actionableRoles.union(["AXStaticText", "AXImage", "AXRow", "AXSearchField"])

    /// Breadth-first walk of the focused window (blocking AX IPC — call off main).
    static func snapshot(pid: pid_t, primaryHeight: CGFloat) -> (nodes: [AXNode], refs: [AXUIElement], menus: [String]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var nodes: [AXNode] = []
        var refs: [AXUIElement] = []
        var queue: [AXUIElement] = []
        if let win = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) { queue.append(win) }
        var head = 0, visited = 0
        while head < queue.count, nodes.count < maxNodes, visited < maxVisited {
            let el = queue[head]; head += 1; visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if interesting.contains(role), let f = frame(el, primaryHeight: primaryHeight), f.width > 1, f.height > 1 {
                let title = [string(el, kAXTitleAttribute), string(el, kAXDescriptionAttribute), string(el, kAXValueAttribute),
                             string(el, kAXPlaceholderValueAttribute)]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? ""
                if role != "AXStaticText" || !title.isEmpty {
                    nodes.append(AXNode(id: nodes.count, role: role, title: String(title.prefix(80)), frame: f))
                    refs.append(el)
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let arr = children as? [AXUIElement] {
                queue.append(contentsOf: arr.prefix(200))
            }
        }
        var menus: [String] = []
        if let bar = element(app, kAXMenuBarAttribute) {
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
               let arr = children as? [AXUIElement] {
                menus = arr.compactMap { string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
            }
        }
        return (nodes, refs, menus)
    }

    /// One line per node, with the center in the screenshot's 0–1000 (y, x) space.
    static func format(_ nodes: [AXNode], mapper: CoordinateMapper?, menus: [String]) -> String {
        var lines = nodes.map { n -> String in
            let role = n.role.replacingOccurrences(of: "AX", with: "")
            let pos: String
            if let mapper {
                let c = mapper.normalized(screen: CGPoint(x: n.frame.midX, y: n.frame.midY))
                pos = " @y=\(Int(c.y)) x=\(Int(c.x))"
            } else { pos = "" }
            return "[\(n.id)] \(role) \"\(n.title)\"\(pos)"
        }
        if !menus.isEmpty { lines.insert("menus: " + menus.joined(separator: " | "), at: 0) }
        return lines.joined(separator: "\n")
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func frame(_ el: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
              let posV, let sizeV else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        return CGRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
    }

    /// Splits "File > New Folder" into ["File", "New Folder"].
    static func menuPath(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ">→")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Parses "cmd+shift+l", "return", "esc" → (keyCode, flags). nil if unknown.
    static func keyCombo(_ s: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: String?
        for part in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default: key = part
            }
        }
        guard let key, let code = keyCodes[key] else { return nil }
        return (code, flags)
    }

    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        ]
        let letters: [(String, CGKeyCode)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("k", 40), ("n", 45), ("m", 46), (",", 43), (".", 47), ("/", 44), (";", 41), ("-", 27), ("=", 24)]
        for (k, v) in letters { m[k] = v }
        return m
    }()
}
