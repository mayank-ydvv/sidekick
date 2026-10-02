import AppKit
import Observation
import QuartzCore

/// Owns the per-screen overlays, the buddy cursor, and on-screen annotations.
@MainActor
final class OverlayController {
    /// Buddy center sits this far bottom-right of the real pointer (AppKit coords, y-up).
    static let followOffset = CGPoint(x: 35, y: -25)
    /// Pointing holds until the user moves the mouse (safety timeout only).
    static let pointHold: TimeInterval = 20
    static let annotationLife: TimeInterval = 6
    static let returnDistance: CGFloat = 40

    private let state: AppState
    private let settings: AppSettings
    private var windows: [OverlayWindow] = []
    private let buddy = BuddyCursorLayer()
    private weak var buddyHost: OverlayWindow?
    private var monitors: [Any] = []
    /// Hidden along with the Mac pointer, which macOS hides while you type text; any mouse movement brings it back.
    private var idleHidden = false

    // User ink (spatial context)
    private(set) var inkEnabled = false
    private(set) var inkStrokes: [[CGPoint]] = []
    private var inkLayers: [CAShapeLayer] = []
    private var inkPath = CGMutablePath()

    private(set) var isPointing = false
    /// Labels next to pointed targets (off: the buddy alone points, like a finger).
    var showPointLabels = false
    private var pointOrigin: CGPoint = .zero
    private var returnWork: DispatchWorkItem?
    private var annotationGen = 0

    /// Buddy's current anchor (global AppKit) — the cursor bubble follows it.
    private(set) var buddyPoint: CGPoint = .zero
    var onBuddyMoved: ((CGPoint, TimeInterval) -> Void)?

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
    }

    func start() {
        rebuildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(l) }
        // Typing text hides the Mac pointer (until the mouse moves) — hide the buddy with it.
        if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.keyTyped(e) }
        }) { monitors.append(k) }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.keyTyped(e) }
            return e
        }) { monitors.append(k) }
        observeState()
        placeBuddyAtRest(animated: false)
    }

    // MARK: Windows

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
        for w in windows {
            w.onInk = { [weak self, weak w] phase, p in
                guard let self, let w else { return }
                self.ink(phase, p, in: w)
            }
            w.ignoresMouseEvents = !inkEnabled
        }
        windows.forEach { $0.orderFrontRegardless() }
        buddyHost = nil
        placeBuddyAtRest(animated: false)
    }

    private func window(containing p: CGPoint) -> OverlayWindow? {
        windows.first { NSMouseInRect(p, $0.screenRef.frame, false) } ?? windows.first
    }

    // MARK: State → mood

    private func observeState() {
        withObservationTracking {
            _ = state.phase
            _ = state.level
            _ = state.alwaysOn
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.applyState()
                self?.observeState()
            } }
        }
        applyState()
    }

    private func applyState() {
        let mood: BuddyCursorLayer.Mood
        switch state.phase {
        case .listening: mood = .listening
        case .transcribing, .thinking: mood = .thinking
        case .speaking: mood = .speaking
        case .idle, .message:
            mood = isPointing ? .pointing : state.alwaysOn ? .listening : (settings.data.showBuddy && !idleHidden ? .idle : .hidden)
        }
        buddy.setMood(isPointing && mood != .listening ? .pointing : mood)
        buddy.setLevel(state.level)
    }

    // MARK: Following

    private func restPoint() -> CGPoint {
        if settings.data.dockBuddy {
            let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
            let inset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            // Tip sits just under the notch / menu bar at top-center.
            return CGPoint(x: screen.frame.midX - 6, y: screen.frame.maxY - inset - 4)
        }
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x + Self.followOffset.x, y: m.y + Self.followOffset.y)
    }

    private func setIdleHidden(_ hidden: Bool) {
        guard hidden != idleHidden else { return }
        idleHidden = hidden
        applyState()
    }

    /// Shortcuts (⌘/⌃ combos) don't hide the Mac pointer; typing text does.
    private func keyTyped(_ e: NSEvent) {
        guard e.modifierFlags.intersection([.command, .control]).isEmpty else { return }
        setIdleHidden(true)
    }

    private func mouseMoved() {
        setIdleHidden(false)
        if isPointing {
            if hypot(NSEvent.mouseLocation.x - pointOrigin.x, NSEvent.mouseLocation.y - pointOrigin.y) > Self.returnDistance {
                endPointing()
            }
            return
        }
        guard !settings.data.dockBuddy else { return }
        // Moves in lockstep with the real pointer (no easing, so it never lags behind).
        move(to: restPoint(), duration: 0)
    }

    func placeBuddyAtRest(animated: Bool) {
        move(to: restPoint(), duration: animated ? Motion.CA.flight : 0)
    }

    /// Moves the buddy's tip to a global point, re-hosting it on another screen if needed.
    private func move(to p: CGPoint, duration: TimeInterval, curved: Bool = false) {
        guard let host = window(containing: p) else { return }
        if buddyHost !== host {
            buddy.removeFromSuperlayer()
            host.root.addSublayer(buddy)
            buddy.setScale(host.scale)
            buddyHost = host
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            buddy.position = host.local(p)
            CATransaction.commit()
            buddyPoint = p
            onBuddyMoved?(p, 0)
            return
        }
        let target = host.local(p)
        let from = (buddy.presentation() ?? buddy).position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buddy.position = target
        CATransaction.commit()
        buddyPoint = p
        onBuddyMoved?(p, duration)
        guard duration > 0 else { buddy.removeAnimation(forKey: "move"); return }

        if curved, !Motion.reduceMotion {
            // Arc upward along a quadratic path, like a little hop.
            let dist = hypot(target.x - from.x, target.y - from.y)
            let ctrl = CGPoint(x: (from.x + target.x) / 2, y: max(from.y, target.y) + min(160, dist * 0.35))
            let path = CGMutablePath()
            path.move(to: from)
            path.addQuadCurve(to: target, control: ctrl)
            let a = CAKeyframeAnimation(keyPath: "position")
            a.path = path
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.2, 1.0)
            buddy.add(a, forKey: "move")
        } else if Motion.reduceMotion, duration > Motion.CA.follow {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 0
            f.toValue = 1
            f.duration = Motion.CA.fade
            buddy.add(f, forKey: "move")
        } else if duration <= Motion.CA.follow {
            // Springy follow with a slight overshoot.
            let a = Motion.CA.spring("position", response: 0.32, damping: 0.7)
            a.fromValue = from
            a.toValue = target
            buddy.add(a, forKey: "move")
        } else {
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = from
            a.toValue = target
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            buddy.add(a, forKey: "move")
        }
    }

    // MARK: User ink

    /// While push-to-talk is held, the overlay accepts drags so the user can mark the screen.
    func beginInkCapture() {
        inkEnabled = true
        inkStrokes = []
        windows.forEach { $0.ignoresMouseEvents = false }
    }

    /// Returns the strokes (global AppKit points) and fades the trail out after 1.5 s.
    func endInkCapture() -> [[CGPoint]] {
        inkEnabled = false
        windows.forEach { $0.ignoresMouseEvents = true }
        let strokes = inkStrokes.filter { $0.count > 1 }
        let layers = inkLayers
        inkLayers = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            layers.forEach { self?.fadeOut($0) }
        }
        return strokes
    }

    /// The talk hotkey's modifiers (ink only makes sense while they're held).
    var inkModifiers: ModifierSet = [.control, .option]

    private func ink(_ phase: InkView.Phase, _ p: CGPoint, in host: OverlayWindow) {
        guard inkEnabled else { return }
        // Safety net: a missed key-up must never leave the overlay swallowing clicks.
        if !ModifierSet(cgFlags: CGEventSource.flagsState(.combinedSessionState)).isSuperset(of: inkModifiers) {
            _ = endInkCapture()
            return
        }
        let lp = host.local(p)
        switch phase {
        case .began:
            inkStrokes.append([p])
            inkPath = CGMutablePath()
            inkPath.move(to: lp)
            let l = Annotation.strokeLayer(inkPath, scale: host.scale)
            l.strokeColor = NSColor.systemRed.cgColor
            l.lineWidth = 6
            host.annotations.addSublayer(l)
            inkLayers.append(l)
        case .moved, .ended:
            guard !inkStrokes.isEmpty, let l = inkLayers.last else { return }
            inkStrokes[inkStrokes.count - 1].append(p)
            inkPath.addLine(to: lp)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.path = inkPath
            CATransaction.commit()
        }
    }

    // MARK: Success

    /// Green check burst at a point (teaching mode: the user clicked the right thing).
    func success(at p: CGPoint) {
        guard let host = window(containing: p) else { return }
        let lp = host.local(p)
        let check = CGMutablePath()
        check.move(to: CGPoint(x: lp.x - 10, y: lp.y))
        check.addLine(to: CGPoint(x: lp.x - 3, y: lp.y - 8))
        check.addLine(to: CGPoint(x: lp.x + 12, y: lp.y + 10))
        let l = Annotation.strokeLayer(check, scale: host.scale)
        l.strokeColor = NSColor.systemGreen.cgColor
        l.lineWidth = 5
        let ring = Annotation.pulseLayer(at: lp, scale: host.scale)
        ring.strokeColor = NSColor.systemGreen.cgColor
        host.annotations.addSublayer(ring)
        host.annotations.addSublayer(l)
        Annotation.drawOn(l)
        buddy.bounce()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.fadeOut(l)
            self?.fadeOut(ring)
        }
    }

    // MARK: Pointing

    /// Flies the buddy so its tip touches `p`, shows an optional label, then returns.
    func point(to p: CGPoint, label: String?) {
        returnWork?.cancel()
        isPointing = true
        pointOrigin = NSEvent.mouseLocation
        applyState()
        // Face the target, then fly so the triangle's tip (not its center) lands on it.
        let heading = atan2(p.y - buddyPoint.y, p.x - buddyPoint.x)
        Log.app.notice("point: from \(self.buddyPoint.x, privacy: .public),\(self.buddyPoint.y, privacy: .public) to \(p.x, privacy: .public),\(p.y, privacy: .public) heading \(Double(heading) * 180 / Double.pi, privacy: .public)°")
        buddy.setHeading(heading, animated: true)
        let landing = CGPoint(x: p.x - cos(heading) * BuddyCursorLayer.tipOffset, y: p.y - sin(heading) * BuddyCursorLayer.tipOffset)
        move(to: landing, duration: Motion.CA.flight, curved: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.CA.flight) { [weak self] in
            guard let self, self.isPointing else { return }
            self.buddy.bounce()
            if self.showPointLabels, let label, let host = self.window(containing: p) {
                self.addLabel(label, near: host.local(p), in: host, gen: self.annotationGen)
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.endPointing() }
        returnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.CA.flight + Self.pointHold, execute: work)
    }

    /// Re-draws attention to a target (teaching hint after a wrong click).
    func repoint(_ t: TeachTarget) {
        if let host = window(containing: t.point) {
            add(Annotation.pulseLayer(at: host.local(t.point), scale: host.scale), to: host, gen: annotationGen, drawOn: false)
        }
        point(to: t.point, label: t.label)
    }

    func endPointing() {
        guard isPointing else { return }
        returnWork?.cancel()
        isPointing = false
        applyState()
        move(to: restPoint(), duration: Motion.CA.flight, curved: true)
    }

    // MARK: Annotations

    /// Renders a model tag on screen. Targets snap to real UI elements via Accessibility when close enough.
    /// Returns the resolved click target (for teaching), if the tag has one.
    @discardableResult
    func annotate(_ tag: OverlayTag, mapper: CoordinateMapper) async -> TeachTarget? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let gen = annotationGen
        switch tag {
        case .point(let y, let x, let label):
            let raw = mapper.screenPoint(normY: y, normX: x)
            let el = await snap(raw, primaryH)
            guard gen == annotationGen else { return nil }
            let target = el?.center ?? raw
            point(to: target, label: label)
            return TeachTarget(point: target, frame: el?.frame, label: label)

        case .circle(let y, let x, let r, let label):
            let raw = mapper.screenPoint(normY: y, normX: x)
            let radius = r.map { CGFloat($0) / 1000 * mapper.displayFrame.width } ?? 36
            let el = await snap(raw, primaryH)
            guard gen == annotationGen else { return nil }
            let rect = el.map { $0.frame.insetBy(dx: -10, dy: -8) }
                ?? CGRect(x: raw.x - radius, y: raw.y - radius, width: radius * 2, height: radius * 2)
            guard let host = window(containing: CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
            add(Annotation.strokeLayer(Annotation.jitteredEllipse(in: host.local(rect)), scale: host.scale), to: host, gen: gen)
            // Buddy perches on the lower-right edge of the circle.
            point(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + rect.height * 0.1), label: label)
            return TeachTarget(point: el?.center ?? raw, frame: el?.frame ?? rect, label: label)

        case .arrow(let fy, let fx, let ty, let tx, let label):
            let from = mapper.screenPoint(normY: fy, normX: fx)
            let rawTo = mapper.screenPoint(normY: ty, normX: tx)
            let el = await snap(rawTo, primaryH)
            guard gen == annotationGen else { return nil }
            let to = el?.center ?? rawTo
            guard let host = window(containing: to) else { return nil }
            add(Annotation.strokeLayer(Annotation.arrowPath(from: host.local(from), to: host.local(to)), scale: host.scale), to: host, gen: gen)
            if let label { addLabel(label, near: host.local(from), in: host, gen: gen) }
            return TeachTarget(point: to, frame: el?.frame, label: label)

        case .highlight(let y1, let x1, let y2, let x2, let label):
            let a = mapper.screenPoint(normY: y1, normX: x1), b = mapper.screenPoint(normY: y2, normX: x2)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            guard rect.width > 2, rect.height > 2, let host = window(containing: CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
            add(Annotation.highlightLayer(host.local(rect), scale: host.scale), to: host, gen: gen)
            if let label { addLabel(label, near: host.local(CGPoint(x: rect.minX, y: rect.maxY + 14)), in: host, gen: gen) }
            return TeachTarget(point: CGPoint(x: rect.midX, y: rect.midY), frame: rect, label: label)

        default:
            return nil
        }
    }

    private func snap(_ p: CGPoint, _ primaryH: CGFloat) async -> AXInspector.Element? {
        await Task.detached(priority: .userInitiated) { AXInspector.snap(p, primaryHeight: primaryH) }.value
    }

    func clearAnnotations() {
        annotationGen += 1
        for w in windows {
            for l in w.annotations.sublayers ?? [] { fadeOut(l) }
        }
        endPointing()
    }

    private func add(_ layer: CAShapeLayer, to host: OverlayWindow, gen: Int, drawOn: Bool = true) {
        host.annotations.addSublayer(layer)
        if drawOn { Annotation.drawOn(layer) }
        scheduleFade(layer, gen: gen)
    }

    private func addLabel(_ text: String, near p: CGPoint, in host: OverlayWindow, gen: Int) {
        let l = LabelBubbleLayer(text, scale: host.scale)
        let size = l.bounds.size
        var pos = CGPoint(x: p.x + 18 + size.width / 2, y: p.y - 30)
        let bounds = host.root.bounds
        pos.x = min(max(size.width / 2 + 8, pos.x), bounds.maxX - size.width / 2 - 8)
        pos.y = min(max(size.height / 2 + 8, pos.y), bounds.maxY - size.height / 2 - 8)
        l.position = pos
        host.annotations.addSublayer(l)
        if !Motion.reduceMotion {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 0
            f.toValue = 1
            f.duration = Motion.CA.fade
            l.add(f, forKey: "in")
        }
        scheduleFade(l, gen: gen)
    }

    private func scheduleFade(_ l: CALayer, gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.annotationLife) { [weak self, weak l] in
            guard let l, self != nil else { return }
            self?.fadeOut(l)
        }
    }

    private func fadeOut(_ l: CALayer) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.CA.fade)
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        CATransaction.commit()
    }

    /// Visual checks only: rotate the resting buddy.
    func debugHeading(_ a: CGFloat) {
        // >= 1000: animated rotation to (a - 1000°); >= 2000: animated + bounce.
        let deg = Double(a) * 180 / Double.pi
        if deg >= 2000 { buddy.setHeading(CGFloat((deg - 2000) * Double.pi / 180), animated: true); buddy.bounce() }
        else if deg >= 1000 { buddy.setHeading(CGFloat((deg - 1000) * Double.pi / 180), animated: true) }
        else { buddy.setHeading(a, animated: false) }
    }

    /// Demo / tutorial: circle the Apple menu on the main display.
    func demo() {
        guard let screen = NSScreen.screens.first else { return }
        clearAnnotations()
        let mapper = CoordinateMapper(displayFrame: screen.frame, imageSize: CGSize(width: 1000, height: 1000))
        let menuH = NSStatusBar.system.thickness
        let y = Double(menuH / 2 / screen.frame.height * 1000)
        let x = Double(20 / screen.frame.width * 1000)
        Task { await annotate(.circle(y: y, x: x, r: nil, label: "the apple menu"), mapper: mapper) }
    }

    func settingsChanged() {
        applyState()
        if !isPointing { placeBuddyAtRest(animated: true) }
    }
}
