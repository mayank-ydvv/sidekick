import AppKit

/// Where the notch is (or a virtual one on screens without a notch). Global AppKit coordinates.
struct NotchGeometry: Equatable {
    var rect: CGRect
    var isVirtual: Bool

    /// A screen without a notch gets a matching black one: the width of a MacBook notch and exactly the height of
    /// that screen's menu bar, attached to the top edge, so it lines up with the menu bar like the real thing.
    static let virtualSize = CGSize(width: 190, height: 32)

    static func forScreen(frame: CGRect, auxLeft: CGRect?, auxRight: CGRect?, safeTop: CGFloat, menuBarHeight: CGFloat? = nil) -> NotchGeometry {
        if let l = auxLeft, let r = auxRight, safeTop > 0, r.minX > l.maxX {
            // The notch is the gap between the two auxiliary areas.
            return NotchGeometry(rect: CGRect(x: l.maxX, y: frame.maxY - safeTop, width: r.minX - l.maxX, height: safeTop),
                                 isVirtual: false)
        }
        var s = virtualSize
        if let m = menuBarHeight, m >= 20 { s.height = m.rounded() }
        return NotchGeometry(rect: CGRect(x: frame.midX - s.width / 2, y: frame.maxY - s.height, width: s.width, height: s.height),
                             isVirtual: true)
    }

    @MainActor
    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        // Menu bar height on this screen (0 when it auto-hides → keep the default).
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return forScreen(frame: screen.frame, auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea,
                         safeTop: screen.safeAreaInsets.top, menuBarHeight: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
    }

    /// O(1) hover check: pointer in the top 6 pt band and within the notch ± 20 pt horizontally.
    func isHotspot(_ p: CGPoint, screenTop: CGFloat) -> Bool {
        p.y >= screenTop - 6 && p.x >= rect.minX - 20 && p.x <= rect.maxX + 20
    }
}
