import AppKit
import QuartzCore

/// Factories for hand-drawn annotation layers (all coordinates are screen-local, y-up).
enum Annotation {
    static let ink = NSColor(red: 1.0, green: 0.33, blue: 0.52, alpha: 1)
    static let lineWidth: CGFloat = 4

    /// A slightly wobbly ellipse that overshoots its start, like a quick pen loop.
    static func jitteredEllipse(in rect: CGRect, wobble: CGFloat = 2.2, turns: CGFloat = 1.1) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let steps = 72
        let start = CGFloat.random(in: 0...(2 * .pi))
        let p1 = CGFloat.random(in: 0...(2 * .pi)), p2 = CGFloat.random(in: 0...(2 * .pi))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = start + t * turns * 2 * .pi
            // Smooth low-frequency wobble + slight spiral so the end doesn't meet the start exactly.
            let w = wobble * (0.6 * sin(3 * a + p1) + 0.4 * sin(5 * a + p2)) + t * wobble * 1.5
            let pt = CGPoint(x: c.x + (rx + w) * cos(a), y: c.y + (ry + w) * sin(a))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    static func arrowPath(from a: CGPoint, to b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        // Gentle curve: control point offset perpendicular to the line.
        let bend: CGFloat = min(40, len * 0.15)
        let ctrl = CGPoint(x: (a.x + b.x) / 2 - dy / len * bend, y: (a.y + b.y) / 2 + dx / len * bend)
        path.move(to: a)
        path.addQuadCurve(to: b, control: ctrl)
        // Arrowhead aligned with the curve's end tangent.
        let ang = atan2(b.y - ctrl.y, b.x - ctrl.x)
        let head: CGFloat = 14
        for s in [-1.0, 1.0] {
            let h = ang + .pi - CGFloat(s) * 0.5
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x + head * cos(h), y: b.y + head * sin(h)))
        }
        return path
    }

    static func strokeLayer(_ path: CGPath, scale: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = path
        l.fillColor = nil
        l.strokeColor = ink.cgColor
        l.lineWidth = lineWidth
        l.lineCap = .round
        l.lineJoin = .round
        l.contentsScale = scale
        l.shadowColor = NSColor.white.cgColor
        l.shadowOpacity = 0.9
        l.shadowRadius = 1.5
        l.shadowOffset = .zero
        return l
    }

    static func highlightLayer(_ rect: CGRect, scale: CGFloat) -> CAShapeLayer {
        let l = strokeLayer(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil), scale: scale)
        l.fillColor = ink.withAlphaComponent(0.12).cgColor
        l.lineWidth = 3
        return l
    }

    /// Expanding ring that marks a point target.
    static func pulseLayer(at p: CGPoint, scale: CGFloat) -> CAShapeLayer {
        let l = strokeLayer(CGPath(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24), transform: nil), scale: scale)
        l.lineWidth = 3
        l.position = p
        l.bounds = .zero
        guard !Motion.reduceMotion else { return l }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 1.1
        g.repeatCount = 3
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(g, forKey: "pulse")
        return l
    }

    static func drawOn(_ l: CAShapeLayer) {
        guard !Motion.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0
        a.toValue = 1
        a.duration = Motion.CA.drawOn
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(a, forKey: "drawOn")
    }
}

/// Small dark pill with a label, used next to buddy targets and annotations.
final class LabelBubbleLayer: CALayer {
    private let text = CATextLayer()

    init(_ string: String, scale: CGFloat) {
        super.init()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = attr.size()
        let w = min(ceil(size.width) + 16, 280), h = ceil(size.height) + 8
        bounds = CGRect(x: 0, y: 0, width: w, height: h)
        backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        cornerRadius = h / 2
        borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        borderWidth = 0.5
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.25
        shadowRadius = 4
        shadowOffset = CGSize(width: 0, height: -1)
        contentsScale = scale
        text.string = attr
        text.contentsScale = scale
        text.truncationMode = .end
        text.frame = CGRect(x: 8, y: 4, width: w - 16, height: h - 8)
        addSublayer(text)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}
