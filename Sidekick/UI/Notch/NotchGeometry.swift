import AppKit

/// Where the notch is (or a virtual one on screens without a notch). Global AppKit coordinates.
struct NotchGeometry: Equatable {
    var rect: CGRect
    var isVirtual: Bool

    static let virtualSize = CGSize(width: 180, height: 32)

    static func forScreen(frame: CGRect, auxLeft: CGRect?, auxRight: CGRect?, safeTop: CGFloat) -> NotchGeometry {
        if let l = auxLeft, let r = auxRight, safeTop > 0, r.minX > l.maxX {
            // The notch is the gap between the two auxiliary areas.
            return NotchGeometry(rect: CGRect(x: l.maxX, y: frame.maxY - safeTop, width: r.minX - l.maxX, height: safeTop),
                                 isVirtual: false)
        }
        let s = virtualSize
        return NotchGeometry(rect: CGRect(x: frame.midX - s.width / 2, y: frame.maxY - s.height, width: s.width, height: s.height),
                             isVirtual: true)
    }

    @MainActor
    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        forScreen(frame: screen.frame, auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea,
                  safeTop: screen.safeAreaInsets.top)
    }

    /// O(1) hover check: pointer in the top 6 pt band and within the notch ± 20 pt horizontally.
    func isHotspot(_ p: CGPoint, screenTop: CGFloat) -> Bool {
        p.y >= screenTop - 6 && p.x >= rect.minX - 20 && p.x <= rect.maxX + 20
    }
}
