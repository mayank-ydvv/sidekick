// Renders Sidekick's original app icon (droplet buddy on a squircle) at 1024 px.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background with a soft indigo → violet gradient (macOS icon grid: 824 px body, centered).
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(bg); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
    NSColor(red: 0.16, green: 0.13, blue: 0.36, alpha: 1).cgColor,
    NSColor(red: 0.36, green: 0.22, blue: 0.62, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
ctx.restoreGState()

// Droplet buddy: tip up-left, round body bottom-right (same geometry as the in-app cursor, scaled).
let s: CGFloat = 19, ox: CGFloat = 250, oy: CGFloat = 230
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
let tip = P(1, 25), c = P(15, 11), r: CGFloat = 10 * s
let d = hypot(tip.x - c.x, tip.y - c.y), dir = atan2(tip.y - c.y, tip.x - c.x), a = acos(r / d)
let drop = CGMutablePath()
drop.move(to: tip)
drop.addLine(to: CGPoint(x: c.x + r * cos(dir - a), y: c.y + r * sin(dir - a)))
drop.addArc(center: c, radius: r, startAngle: dir - a, endAngle: dir + a - 2 * .pi, clockwise: true)
drop.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(drop); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(drop); ctx.clip()
let body = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
    NSColor(red: 0.53, green: 0.62, blue: 1.0, alpha: 1).cgColor,
    NSColor(red: 0.86, green: 0.48, blue: 1.0, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(body, start: tip, end: P(26, 1), options: [])
ctx.restoreGState()
// Eyes.
ctx.setFillColor(NSColor.white.cgColor)
for x in [11.6, 17.6] as [CGFloat] {
    ctx.fillEllipse(in: CGRect(x: ox + (x - 1.6) * s, y: oy + 10.5 * s, width: 3.2 * s, height: 4.4 * s))
}
// Smile.
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(1.3 * s)
ctx.setLineCap(.round)
ctx.addArc(center: P(14.6, 8.2), radius: 2.4 * s, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
ctx.strokePath()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon → \(CommandLine.arguments[1])")
