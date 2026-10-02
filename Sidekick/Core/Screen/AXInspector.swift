import AppKit
import ApplicationServices

/// Finds real, clickable UI elements near a point so annotations land exactly on them.
enum AXInspector {
    struct Element: Equatable, Sendable {
        var role: String
        var title: String?
        /// Frame in global AppKit coordinates (origin bottom-left of the primary display).
        var frame: CGRect
        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXRadioButton", "AXCheckBox",
        "AXTab", "AXSlider", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
        "AXSegmentedControl", "AXDockItem", "AXCell",
    ]

    /// Probe offsets (points) around the target: center, then rings at 20 and 40 pt.
    static let probes: [CGPoint] = {
        var p = [CGPoint.zero]
        for r in [20.0, 40.0] {
            for k in 0..<8 {
                let a = Double(k) * .pi / 4
                p.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
            }
        }
        return p
    }()

    /// Returns the actionable element within `radius` of `point` (AppKit global), or nil.
    /// Blocking AX IPC — call off the main thread.
    static func snap(_ point: CGPoint, radius: CGFloat = 40, primaryHeight: CGFloat) -> Element? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var best: (Element, CGFloat)?
        var seen: [CGRect] = []

        for off in probes {
            let p = CGPoint(x: point.x + off.x, y: point.y + off.y)
            let q = CoordinateMapper.quartz(fromAppKit: p, primaryHeight: primaryHeight)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(q.x), Float(q.y), &hit) == .success, let hit else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(hit, &pid)
            if pid == ownPID { continue }
            guard let el = actionableAncestor(of: hit, primaryHeight: primaryHeight), !seen.contains(el.frame) else { continue }
            seen.append(el.frame)
            let d = distance(from: point, to: el.frame)
            guard d <= radius else { continue }
            // Prefer containment, then the smallest element (most specific), then nearest.
            let score = d * 1000 + el.frame.width * el.frame.height / 1000
            if best == nil || score < best!.1 { best = (el, score) }
            if off == .zero, d == 0 { break }   // direct hit on an actionable element
        }
        return best?.0
    }

    static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func actionableAncestor(of start: AXUIElement, primaryHeight: CGFloat) -> Element? {
        var el: AXUIElement? = start
        for _ in 0..<4 {
            guard let cur = el else { return nil }
            if let role = string(cur, kAXRoleAttribute), actionableRoles.contains(role),
               let frame = frame(cur, primaryHeight: primaryHeight),
               frame.width >= 4, frame.height >= 4, frame.width <= 900, frame.height <= 320 {
                let title = string(cur, kAXTitleAttribute) ?? string(cur, kAXDescriptionAttribute)
                return Element(role: role, title: title, frame: frame)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            el = (parent as! AXUIElement)
        }
        return nil
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func frame(_ el: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
              let posV, let sizeV,
              CFGetTypeID(posV) == AXValueGetTypeID(), CFGetTypeID(sizeV) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        // Quartz top-left → AppKit bottom-left.
        return CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
    }
}
