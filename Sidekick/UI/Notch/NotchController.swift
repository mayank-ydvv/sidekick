import AppKit
import Observation
import SwiftUI

/// UI state shared by the notch panel and its SwiftUI content.
@MainActor
@Observable
final class NotchUIState {
    enum Size: Equatable { case closed, peek, compact, expanded }

    /// What Sidekick is doing, shown in the closed notch like a live activity.
    enum Activity: Equatable {
        case none, listening, thinking, speaking, dictating, working
        case message(String)

        var label: String {
            switch self {
            case .none: ""
            case .listening: "Listening"
            case .thinking: "Thinking"
            case .speaking: "Speaking"
            case .dictating: "Dictating"
            case .working: "Working"
            case .message(let m): m
            }
        }

        var tint: Color {
            switch self {
            case .listening, .dictating: Color(red: 0x66 / 255, green: 0xF1 / 255, blue: 0xFE / 255)
            case .thinking: Color(red: 0xCB / 255, green: 0x65 / 255, blue: 0xB7 / 255)
            case .speaking: Color(red: 1.0, green: 0.62, blue: 0.27)
            case .working: Color(red: 0.96, green: 0.65, blue: 0.55)
            case .message: Color(white: 0.6)
            case .none: .clear
            }
        }
    }

    var activity: Activity = .none
    /// Mic level for the listening bars (0…1).
    var activityLevel: Float = 0
    static let activityWidth: CGFloat = 352
    /// Messages ("didn't catch that") are shown on a strip *below* the camera notch, so nothing hides behind it.
    static let messageWidth: CGFloat = 420
    /// One line for short messages, two for long ones (≈ 48 characters fit on a line).
    var messageStrip: CGFloat {
        if case .message(let m) = activity, m.count > 46 { return 64 }
        return 44
    }

    var isMessage: Bool { if case .message = activity { true } else { false } }
    /// Flared "ears" where the shape meets the top edge of the screen.
    static let ear: CGFloat = 7

    var size: Size = .closed
    /// Drives the content fade-in, set ~80 ms after the morph starts.
    var contentVisible = false
    var pinned = false
    var poppedOut = false
    var sidebarVisible = true
    var inputFocused = false
    var menuOpen = false
    var userScrolledUp = false
    var unread = 0
    /// Opened by the keyboard shortcut / a click: go straight to the focused text field.
    var wantsTyping = false
    /// A notes-wiki page shown in place of the chat.
    var viewingNote: String?
    var notch = CGSize(width: 180, height: 32)
    var expandedSize: CGSize = {
        let w = UserDefaults.standard.double(forKey: "notch.expanded.w"), h = UserDefaults.standard.double(forKey: "notch.expanded.h")
        return w > 0 ? CGSize(width: w, height: h) : CGSize(width: 900, height: 640)
    }() {
        didSet {
            UserDefaults.standard.set(expandedSize.width, forKey: "notch.expanded.w")
            UserDefaults.standard.set(expandedSize.height, forKey: "notch.expanded.h")
        }
    }

    static let peekSize = CGSize(width: 450, height: 198)
    static let compactSize = CGSize(width: 907, height: 626)
    static let minSize = CGSize(width: 520, height: 360)

    var isOpen: Bool { size != .closed }

    var targetSize: CGSize {
        switch size {
        case .closed: closedSize
        case .peek: peekSize
        case .compact: Self.compactSize
        case .expanded: expandedSize
        }
    }

    var cornerRadius: CGFloat { size == .closed ? (closedSize.height > notch.height ? 14 : 10) : 22 }

    /// Dynamic Island content (music, timers, alerts…) shown when Sidekick itself is idle.
    var island: IslandHub?
    /// What the closed island currently shows. Lags behind the hub on purpose so it can animate: the shape grows
    /// first and the content fades in; on the way out the content fades first and then the shape shrinks.
    var islandLayout: IslandLayout?
    var islandAlert: IslandAlert?
    var islandItem: IslandLive?
    var islandContentVisible = false

    /// The closed shape: plain notch, Sidekick's own activity, or island content (sides / strip below).
    var closedSize: CGSize {
        if activity != .none {
            return isMessage ? CGSize(width: Self.messageWidth, height: notch.height + messageStrip)
                             : CGSize(width: Self.activityWidth, height: notch.height)
        }
        switch islandLayout {
        case .sides: return CGSize(width: Self.activityWidth, height: notch.height)
        case .strip(let h): return CGSize(width: Self.messageWidth, height: notch.height + h)
        case nil: return CGSize(width: notch.width + Self.ear * 2, height: notch.height)
        }
    }

    /// Hover: island cards when something's live, otherwise the chat preview.
    var peekSize: CGSize { island?.hasCards == true ? island!.peekSize(notchHeight: notch.height) : Self.peekSize }

    /// Size the content is laid out at. Set instantly (no animation) when opening, so the chat
    /// never re-lays out during the morph — only the mask/shape animates.
    var contentSize: CGSize = NotchUIState.compactSize
    /// Content stays mounted after the first open (no rebuild per open).
    var contentMounted = false
}

/// The AI living in the notch: an invisible-looking black shape over the real notch that
/// morphs into a chat panel on hover (120 ms dwell) and folds back when the pointer leaves (350 ms grace).
@MainActor
final class NotchController {
    let ui = NotchUIState()
    private let panel: NotchPanel
    private var geometry: NotchGeometry
    private var screen: NSScreen
    private var monitors: [Any] = []
    private var dwell: DispatchWorkItem?
    private var leave: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private(set) var popoutWindow: NSWindow?
    private let makeContent: (NotchController) -> AnyView
    var isStreaming: () -> Bool = { false }
    var hoverEnabled: () -> Bool = { true }
    var onOpen: (() -> Void)?

    static let dwellTime: TimeInterval = 0.4
    static let graceTime: TimeInterval = 0.06

    init(content: @escaping (NotchController) -> AnyView) {
        makeContent = content
        screen = NotchController.preferredScreen()
        geometry = NotchGeometry.forScreen(screen)
        panel = NotchPanel()
        ui.notch = geometry.rect.size
        panel.contentView = NSHostingView(rootView: NotchRootView(ui: ui, controller: self))
        panel.setFrame(frame(for: closedFrameSize), display: false)
        panel.orderFrontRegardless()
    }

    /// The closed panel is wide enough for the live-activity pill (transparent beyond the shape).
    private var closedFrameSize: CGSize {
        let c = ui.closedSize
        return CGSize(width: max(NotchUIState.activityWidth, c.width), height: max(geometry.rect.height, c.height))
    }

    private var lastClosedFrame: CGSize = .zero

    /// Island content changed while closed: grow the (transparent) panel before the shape grows, shrink it after
    /// the shape has shrunk, so the panel never blocks clicks below the notch longer than needed.
    // MARK: Island animation

    static let islandGrow = Animation.spring(response: 0.7, dampingFraction: 0.82)
    static let islandShrink = Animation.spring(response: 0.6, dampingFraction: 0.92)
    private var islandHideWork: DispatchWorkItem?

    /// Moves the closed island toward what the hub wants to show, with iPhone-like timing.
    func refreshIsland() {
        guard let hub = ui.island else { return }
        let layout = hub.closedLayout
        if let layout {
            islandHideWork?.cancel(); islandHideWork = nil
            let appearing = ui.islandLayout == nil || !ui.islandContentVisible
            if appearing {
                ui.islandAlert = hub.alert
                ui.islandItem = hub.closedItem
                if ui.islandLayout == nil { ui.islandContentVisible = false }
                withAnimation(Self.islandGrow) { ui.islandLayout = layout }
                refreshClosed()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                    guard let self, self.ui.islandLayout != nil else { return }
                    withAnimation(.easeOut(duration: 0.5)) { self.ui.islandContentVisible = true }
                }
            } else {
                // Switching content (music → timer, alert → music): crossfade, and morph the shape if needed.
                withAnimation(.easeInOut(duration: 0.3)) {
                    ui.islandAlert = hub.alert
                    ui.islandItem = hub.closedItem
                }
                if layout != ui.islandLayout {
                    withAnimation(Self.islandGrow) { ui.islandLayout = layout }
                    refreshClosed()
                }
            }
        } else if ui.islandLayout != nil, islandHideWork == nil {
            // Fade the content out first, then fold the shape back into the notch.
            withAnimation(.easeIn(duration: 0.35)) { ui.islandContentVisible = false }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.islandHideWork = nil
                guard self.ui.island?.closedLayout == nil else { self.refreshIsland(); return }
                withAnimation(Self.islandShrink) { self.ui.islandLayout = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    guard let self, self.ui.islandLayout == nil else { return }
                    self.ui.islandAlert = nil
                    self.ui.islandItem = nil
                    self.refreshClosed()
                }
            }
            islandHideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }

    func refreshClosed() {
        guard !ui.isOpen else { return }
        let target = closedFrameSize
        guard target != lastClosedFrame else { return }
        if target.height >= lastClosedFrame.height {
            panel.setFrame(frame(for: target), display: true)
            lastClosedFrame = target
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self, !self.ui.isOpen else { return }
                let now = self.closedFrameSize
                self.panel.setFrame(self.frame(for: now), display: true)
                self.lastClosedFrame = now
            }
        }
    }

    /// Shows / clears the live activity in the closed notch.
    func setActivity(_ a: NotchUIState.Activity) {
        guard a != ui.activity else { return }
        withAnimation(Motion.smooth) { ui.activity = a }
        refreshClosed()
    }

    func content() -> AnyView { makeContent(self) }

    static func preferredScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(l) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel, e.keyCode == 53 else { return e }   // Esc closes
            MainActor.assumeIsolated { self.close() }
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func screensChanged() {
        screen = Self.preferredScreen()
        geometry = NotchGeometry.forScreen(screen)
        ui.notch = geometry.rect.size
        panel.setFrame(frame(for: ui.isOpen ? ui.targetSize : closedFrameSize), display: true)
    }

    // MARK: Hover

    private func mouseMoved() {
        guard !ui.poppedOut else { return }
        let p = NSEvent.mouseLocation
        if !ui.isOpen {
            if hoverEnabled(), geometry.isHotspot(p, screenTop: screen.frame.maxY) {
                if dwell == nil {
                    let w = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.dwell = nil
                        if self.geometry.isHotspot(NSEvent.mouseLocation, screenTop: self.screen.frame.maxY) { self.open(.peek) }
                    }
                    dwell = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellTime, execute: w)
                }
            } else {
                dwell?.cancel(); dwell = nil
            }
            return
        }
        // Open: close after the pointer has been outside for the grace period.
        let inside = panel.frame.insetBy(dx: -8, dy: -8).contains(p)
        if inside {
            leave?.cancel(); leave = nil
        } else if leave == nil, shouldAutoClose {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.leave = nil
                if !self.panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation), self.shouldAutoClose { self.close() }
            }
            leave = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.graceTime, execute: w)
        }
    }

    var shouldAutoClose: Bool {
        !(ui.pinned || isTyping || ui.menuOpen || (isStreaming() && ui.userScrolledUp))
    }

    /// True while the panel is key and a text view (field editor) has focus — never stale.
    var isTyping: Bool {
        panel.isKeyWindow && panel.firstResponder is NSTextView
    }

    // MARK: Open / close / resize

    func toggle() { ui.isOpen ? close() : open(.compact, focus: true) }

    func open(_ size: NotchUIState.Size, focus: Bool = false) {
        guard !ui.poppedOut else { popoutWindow?.makeKeyAndOrderFront(nil); return }
        shrinkWork?.cancel()
        onOpen?()
        let target = size == .compact && ui.size == .expanded ? .expanded : size
        let from = ui.targetSize
        let to: CGSize = {
            switch target {
            case .peek: ui.peekSize
            case .compact: NotchUIState.compactSize
            case .expanded: ui.expandedSize
            case .closed: closedFrameSize
            }
        }()
        // Window grows first (max of both sizes), the shape springs inside it.
        panel.setFrame(frame(for: CGSize(width: max(from.width, to.width), height: max(from.height, to.height))), display: true)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            ui.contentSize = to
            ui.contentMounted = true
        }
        withAnimation(Motion.smooth) { ui.size = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.ui.isOpen else { return }
            withAnimation(Motion.fade) { self.ui.contentVisible = true }
        }
        scheduleShrink(to: to)
        if focus || target != .peek {
            panel.makeKey()
        }
        if focus, target != .peek { ui.wantsTyping = true }
    }

    func close() {
        guard ui.isOpen else { return }
        leave?.cancel(); leave = nil
        withAnimation(.easeOut(duration: Motion.CA.fadeFast)) { ui.contentVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            withAnimation(Motion.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.9)) {
                self.ui.size = .closed
            }
            self.scheduleShrink(to: self.closedFrameSize)
            self.lastClosedFrame = self.closedFrameSize
        }
        ui.inputFocused = false
        ui.wantsTyping = false
        panel.resignKey()
    }

    /// After the spring settles, trim the window to the visible shape so nothing else is covered.
    private func scheduleShrink(to size: CGSize) {
        shrinkWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.setFrame(self.frame(for: size), display: true)
        }
        shrinkWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    /// Edge-drag resizing (switches to the remembered "expanded" size).
    func resize(by delta: CGSize, from start: CGSize) {
        let vf = screen.visibleFrame
        let w = min(max(start.width + delta.width, NotchUIState.minSize.width), vf.width - 40)
        let h = min(max(start.height + delta.height, NotchUIState.minSize.height), vf.height - 20)
        ui.expandedSize = CGSize(width: w, height: h)
        ui.contentSize = ui.expandedSize
        ui.size = .expanded
        shrinkWork?.cancel()
        panel.setFrame(frame(for: ui.expandedSize), display: true)
    }

    func resetSize() {
        ui.expandedSize = CGSize(width: 900, height: 640)
        open(.compact)
    }

    private func frame(for size: CGSize) -> CGRect {
        CGRect(x: geometry.rect.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: Pop-out

    func popOut() {
        guard !ui.poppedOut else { return }
        close()
        ui.poppedOut = true
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "sidekick"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NotchUIState.minSize
        w.contentView = NSHostingView(rootView: content().environment(\.notchPoppedOut, true))
        w.setFrameAutosaveName("SidekickPopout")
        if w.frame.origin == .zero { w.center() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tuckBack(closing: true) }
        }
        popoutWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "notch.poppedOut")
    }

    func tuckBack(closing: Bool = false) {
        guard ui.poppedOut else { return }
        ui.poppedOut = false
        UserDefaults.standard.set(false, forKey: "notch.poppedOut")
        if !closing { popoutWindow?.close() }
        popoutWindow = nil
        open(.compact)
    }

    func restorePopOutIfNeeded() {
        if UserDefaults.standard.bool(forKey: "notch.poppedOut") { popOut() }
    }
}

/// Non-activating, borderless panel above the menu bar. Becomes key only for typing.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PoppedOutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var notchPoppedOut: Bool {
        get { self[PoppedOutKey.self] }
        set { self[PoppedOutKey.self] = newValue }
    }
}
