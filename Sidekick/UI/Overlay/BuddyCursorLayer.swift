import AppKit
import QuartzCore

/// The buddy cursor: a small red rounded triangle with a soft glow, sitting beside the real pointer.
/// It morphs into waveform bars while listening, fades with a spinner while thinking, pulses while speaking,
/// and rotates to face where it flies when pointing. All motion is Core Animation (render server).
final class BuddyCursorLayer: CALayer {
    enum Mood: Equatable { case idle, listening, thinking, speaking, pointing, hidden }

    static let size = CGSize(width: 40, height: 40)
    static let tint = NSColor(red: 0xF2 / 255.0, green: 0x3B / 255.0, blue: 0x3B / 255.0, alpha: 1)
    /// Triangle geometry (pointing right, centered in the layer).
    static let triWidth: CGFloat = 12.5
    static let triHeight: CGFloat = 13
    /// Distance from the layer center to the triangle's tip (used to land the tip on a target).
    /// Measured from the rounded path, so the visible tip (not the sharp corner) lands on targets.
    static let tipOffset: CGFloat = trianglePath().boundingBoxOfPath.maxX

    private let triangle = CAShapeLayer()
    private let bars = CALayer()
    private var barLayers: [CALayer] = []
    private let spinner = CAShapeLayer()
    private(set) var mood: Mood = .idle
    private var levelPhase: CGFloat = 0

    override init() {
        super.init()
        bounds = CGRect(origin: .zero, size: Self.size)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        setup()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ s: CGFloat) {
        for l in [self, triangle, bars, spinner] { l.contentsScale = s }
        barLayers.forEach { $0.contentsScale = s }
    }

    /// Play-glyph triangle pointing right, centered on (0,0), with evenly rounded, soft corners.
    static func trianglePath() -> CGPath {
        let w = triWidth, h = triHeight
        let a = CGPoint(x: -w / 3, y: h / 2), b = CGPoint(x: w * 2 / 3, y: 0), c = CGPoint(x: -w / 3, y: -h / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        p.addArc(tangent1End: a, tangent2End: b, radius: 2.8)
        p.addArc(tangent1End: b, tangent2End: c, radius: 2.8)
        p.addArc(tangent1End: c, tangent2End: a, radius: 2.8)
        p.closeSubpath()
        return p
    }

    private func setup() {
        let center = CGPoint(x: Self.size.width / 2, y: Self.size.height / 2)
        triangle.path = Self.trianglePath()
        triangle.position = center
        triangle.fillColor = Self.tint.cgColor
        triangle.shadowColor = Self.tint.cgColor
        triangle.shadowOpacity = 0.55
        triangle.shadowRadius = 9
        triangle.shadowOffset = .zero
        addSublayer(triangle)

        // Listening: 6 thin bars.
        bars.frame = CGRect(x: center.x - 11, y: center.y - 8, width: 22, height: 16)
        for i in 0..<6 {
            let b = CALayer()
            b.backgroundColor = Self.tint.cgColor
            b.cornerRadius = 1
            b.frame = CGRect(x: CGFloat(i) * 4, y: 6, width: 2, height: 4)
            bars.addSublayer(b)
            barLayers.append(b)
        }
        bars.opacity = 0
        addSublayer(bars)

        // Thinking: a thin arc spinner.
        spinner.path = CGPath(ellipseIn: CGRect(x: -8, y: -8, width: 16, height: 16), transform: nil)
        spinner.position = center
        spinner.fillColor = nil
        spinner.strokeColor = Self.tint.cgColor
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.7
        spinner.opacity = 0
        addSublayer(spinner)
    }

    func setMood(_ m: Mood) {
        guard m != mood else { return }
        let old = mood
        mood = m
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.CA.fade)
        // Hiding/showing alongside the Mac pointer is instant, like the pointer itself.
        CATransaction.setDisableActions((old == .hidden && m == .idle) || (old == .idle && m == .hidden))
        opacity = m == .hidden ? 0 : 1
        triangle.opacity = m == .listening ? 0 : (m == .thinking ? 0.35 : 1)
        triangle.transform = m == .listening ? CATransform3DMakeScale(0.4, 0.4, 1) : CATransform3DIdentity
        bars.opacity = m == .listening ? 1 : 0
        spinner.opacity = m == .thinking ? 1 : 0
        CATransaction.commit()

        spinner.removeAnimation(forKey: "spin")
        triangle.removeAnimation(forKey: "speak")
        if m == .thinking, !Motion.reduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.8
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        }
        if m == .speaking, !Motion.reduceMotion {
            // Glow + size pulse while talking.
            let glow = CABasicAnimation(keyPath: "shadowRadius")
            glow.fromValue = 8
            glow.toValue = 14
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1.0
            grow.toValue = 1.18
            let g = CAAnimationGroup()
            g.animations = [glow, grow]
            g.duration = 0.32
            g.autoreverses = true
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            triangle.add(g, forKey: "speak")
        }
        if m != .pointing { setHeading(0, animated: true) }
    }

    /// Waveform bars follow the mic level (with a little per-bar variation).
    func setLevel(_ level: Float) {
        guard mood == .listening else { return }
        levelPhase += 0.9
        let weights: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.9, 0.55]
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        for (i, b) in barLayers.enumerated() {
            let wobble = 0.75 + 0.25 * sin(levelPhase + CGFloat(i) * 1.3)
            let h = max(3, min(16, 3 + CGFloat(level) * 30 * weights[i] * wobble))
            b.frame = CGRect(x: CGFloat(i) * 4, y: 8 - h / 2, width: 2, height: h)
        }
        CATransaction.commit()
    }

    /// Rotates the triangle to face `angle` (radians, 0 = right).
    func setHeading(_ angle: CGFloat, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        triangle.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    /// Little "boing" on arrival / success.
    func bounce() {
        guard !Motion.reduceMotion else { return }
        let s = Motion.CA.spring("transform.scale", response: 0.4, damping: 0.5)
        s.fromValue = 1.4
        s.toValue = 1.0
        triangle.add(s, forKey: "bounce")
    }
}
