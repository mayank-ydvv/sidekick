import CoreGraphics

/// Maps between Gemini's normalized 0–1000 coordinates (y first), screenshot pixels,
/// and global screen points (AppKit coordinates: origin bottom-left of the primary display).
struct CoordinateMapper: Equatable, Sendable {
    /// Display frame in global AppKit points.
    let displayFrame: CGRect
    /// Size of the (downscaled) screenshot image in pixels.
    let imageSize: CGSize

    /// Normalized (0–1000) → screenshot pixel (top-left origin).
    func imagePoint(normY: Double, normX: Double) -> CGPoint {
        CGPoint(x: clamp(normX) / 1000 * imageSize.width,
                y: clamp(normY) / 1000 * imageSize.height)
    }

    /// Normalized (0–1000) → global AppKit screen point.
    func screenPoint(normY: Double, normX: Double) -> CGPoint {
        let fx = clamp(normX) / 1000
        let fy = clamp(normY) / 1000
        return CGPoint(x: displayFrame.minX + fx * displayFrame.width,
                       y: displayFrame.maxY - fy * displayFrame.height)
    }

    /// Global AppKit screen point → normalized (y, x).
    func normalized(screen p: CGPoint) -> (y: Double, x: Double) {
        let fx = (p.x - displayFrame.minX) / displayFrame.width
        let fy = (displayFrame.maxY - p.y) / displayFrame.height
        return (y: clamp(fy * 1000), x: clamp(fx * 1000))
    }

    /// Screenshot pixel (top-left origin) → global AppKit point.
    func screenPoint(imagePixel p: CGPoint) -> CGPoint {
        let n = (y: p.y / imageSize.height * 1000, x: p.x / imageSize.width * 1000)
        return screenPoint(normY: n.y, normX: n.x)
    }

    /// Converts a global AppKit point to Quartz/CG global coordinates (origin top-left of primary display).
    static func quartz(fromAppKit p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func appKit(fromQuartz p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Size to downscale a capture to so its long side is `maxLongSide` (never upscales).
    static func downscaledSize(for size: CGSize, maxLongSide: CGFloat = 1280) -> CGSize {
        let long = max(size.width, size.height)
        guard long > maxLongSide, long > 0 else { return size }
        let s = maxLongSide / long
        return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }

    private func clamp(_ v: Double) -> Double { min(1000, max(0, v)) }
}
