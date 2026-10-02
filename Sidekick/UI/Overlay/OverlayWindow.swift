import AppKit
import QuartzCore

/// Transparent, click-through, non-activating panel covering one display.
/// Excluded from screenshots and screen sharing.
final class OverlayWindow: NSPanel {
    let screenRef: NSScreen
    let root = CALayer()
    let annotations = CALayer()

    init(screen: NSScreen) {
        screenRef = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = DebugFlags.capturable ? .readOnly : .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let view = InkView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.owner = self
        view.wantsLayer = true
        view.layer = root
        view.layerContentsRedrawPolicy = .never
        root.frame = view.bounds
        root.masksToBounds = false
        annotations.frame = root.bounds
        root.addSublayer(annotations)
        contentView = view
        setFrame(screen.frame, display: false)
    }

    var scale: CGFloat { screenRef.backingScaleFactor }

    /// Global AppKit point → this window's layer coordinates.
    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenRef.frame.minX, y: p.y - screenRef.frame.minY) }
    func local(_ r: CGRect) -> CGRect { CGRect(origin: local(r.origin), size: r.size) }

    /// Drag callbacks while ink capture is on (global AppKit points).
    var onInk: ((InkView.Phase, CGPoint) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives drags only while the overlay accepts mouse events (push-to-talk held).
final class InkView: NSView {
    enum Phase { case began, moved, ended }
    weak var owner: OverlayWindow?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func send(_ phase: Phase, _ e: NSEvent) {
        guard let w = owner else { return }
        let p = w.convertPoint(toScreen: e.locationInWindow)
        w.onInk?(phase, p)
    }
    override func mouseDown(with e: NSEvent) { send(.began, e) }
    override func mouseDragged(with e: NSEvent) { send(.moved, e) }
    override func mouseUp(with e: NSEvent) { send(.ended, e) }
    // ⌃-click can arrive as a right-click; treat it the same.
    override func rightMouseDown(with e: NSEvent) { send(.began, e) }
    override func rightMouseDragged(with e: NSEvent) { send(.moved, e) }
    override func rightMouseUp(with e: NSEvent) { send(.ended, e) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
