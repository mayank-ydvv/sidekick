import AppKit
import SwiftUI

/// Opens regular windows (onboarding, settings) for this menu-bar app.
@MainActor
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(id: String, title: String, size: CGSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        w.center()
        windows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close(id: String) {
        windows[id]?.close()
        windows[id] = nil
    }
}
