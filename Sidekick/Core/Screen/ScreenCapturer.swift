import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import ImageIO

/// What the user is looking at, held in memory only. Never written to disk.
struct ScreenContext: @unchecked Sendable {
    var jpeg: Data
    /// Kept (in memory only) so user ink can be burned in before sending.
    var image: CGImage
    var mapper: CoordinateMapper
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var mouse: CGPoint
}

/// Captures the display under the cursor via ScreenCaptureKit, excluding Sidekick's own windows.
actor ScreenCapturer {
    private var cachedContent: SCShareableContent?

    /// Drop cached displays (call on screen-configuration changes).
    func invalidate() { cachedContent = nil }

    /// Pre-fetch shareable content so the first capture is fast.
    func warm() async { _ = try? await content() }

    private func content() async throws -> SCShareableContent {
        if let cachedContent { return cachedContent }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = c
        return c
    }

    func capture(readBrowserURL: Bool) async throws -> ScreenContext {
        let start = ProcessInfo.processInfo.systemUptime
        // Gather main-thread state first.
        let info = await MainActor.run { () -> (CGDirectDisplayID?, CGRect, CGPoint, NSRunningApplication?) in
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return (id, screen?.frame ?? .zero, mouse, NSWorkspace.shared.frontmostApplication)
        }
        let (displayID, frame, mouse, app) = info

        // Front-app context runs in parallel with the capture.
        async let meta = Self.frontContext(app: app, readURL: readBrowserURL)

        var content = try await content()
        var display = content.displays.first { $0.displayID == displayID }
        if display == nil {
            cachedContent = nil
            content = try await self.content()
            display = content.displays.first { $0.displayID == displayID } ?? content.displays.first
        }
        guard let display else { throw CaptureError.noDisplay }

        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let pixelSize = CGSize(width: CGFloat(display.width) * 2, height: CGFloat(display.height) * 2)
        let target = CoordinateMapper.downscaledSize(for: pixelSize, maxLongSide: 1280)
        config.width = Int(target.width)
        config.height = Int(target.height)
        config.showsCursor = true
        config.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = Self.encodeJPEG(image, quality: 0.7) else { throw CaptureError.encodeFailed }
        let m = await meta
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        Log.perf.notice("screenshot \(Int(ms))ms \(image.width)x\(image.height) \(jpeg.count / 1024)KB")
        return ScreenContext(
            jpeg: jpeg,
            image: image,
            mapper: CoordinateMapper(displayFrame: frame, imageSize: CGSize(width: image.width, height: image.height)),
            appName: m.appName, bundleID: m.bundleID, windowTitle: m.title, url: m.url, mouse: mouse
        )
    }

    /// Draws the user's red ink strokes onto the screenshot and re-encodes it. Off-main.
    static func burnInk(_ strokes: [[CGPoint]], into ctx: ScreenContext) -> ScreenContext {
        let img = ctx.image
        let w = img.width, h = img.height
        guard !strokes.isEmpty,
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return ctx }
        cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        cg.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        cg.setLineWidth(6)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for stroke in strokes {
            let pts = stroke.map { p -> CGPoint in
                let n = ctx.mapper.normalized(screen: p)
                let ip = ctx.mapper.imagePoint(normY: n.y, normX: n.x)
                return CGPoint(x: ip.x, y: CGFloat(h) - ip.y)   // image is top-left origin; CG is bottom-left
            }
            guard let first = pts.first else { continue }
            cg.move(to: first)
            pts.dropFirst().forEach { cg.addLine(to: $0) }
            cg.strokePath()
        }
        guard let out = cg.makeImage(), let jpeg = encodeJPEG(out, quality: 0.7) else { return ctx }
        var copy = ctx
        copy.image = out
        copy.jpeg = jpeg
        return copy
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    struct FrontMeta: Sendable { var appName: String?; var bundleID: String?; var title: String?; var url: String? }

    static func frontContext(app: NSRunningApplication?, readURL: Bool) async -> FrontMeta {
        guard let app else { return FrontMeta() }
        var meta = FrontMeta(appName: app.localizedName, bundleID: app.bundleIdentifier)
        meta.title = AXHelpers.focusedWindowTitle(pid: app.processIdentifier)
        if readURL, let bid = app.bundleIdentifier, let script = BrowserURL.script(for: bid) {
            meta.url = await BrowserURL.run(script, timeout: 0.4)
        }
        return meta
    }

    enum CaptureError: LocalizedError {
        case noDisplay, encodeFailed
        var errorDescription: String? {
            switch self {
            case .noDisplay: "couldn't find a display to look at"
            case .encodeFailed: "couldn't process the screenshot"
            }
        }
    }
}

enum AXHelpers {
    static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}

enum BrowserURL {
    static func script(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return "tell application id \"\(bundleID)\" to return URL of front document"
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
             "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi":
            return "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        default:
            return nil
        }
    }

    private static let queue = DispatchQueue(label: "sidekick.applescript", qos: .userInitiated)

    /// Runs an AppleScript off-main with a timeout; returns nil on failure or timeout.
    static func run(_ source: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = OnceFlag()
            queue.async {
                var err: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
                if once.claim() { cont.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
