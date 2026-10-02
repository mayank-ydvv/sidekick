import SwiftUI

/// The black shape that morphs out of the notch. Only GPU-friendly properties animate:
/// the shape's size/corner radius, plus content opacity/scale/blur.
struct NotchRootView: View {
    @Bindable var ui: NotchUIState
    let controller: NotchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGSize?
    @State private var dragMouse: CGPoint?

    var body: some View {
        let shapeSize = ui.targetSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(Color.black)
                    .frame(width: shapeSize.width, height: shapeSize.height)
                    // Fixed-radius shadow whose opacity fades (cheap) instead of animating the radius.
                    .shadow(color: .black.opacity(ui.isOpen ? 0.35 : 0), radius: 16, y: 8)
                if ui.contentMounted {
                    content
                        .padding(.top, ui.size == .peek ? ui.notch.height : ui.notch.height - 4)
                        .frame(width: ui.contentSize.width, height: ui.contentSize.height, alignment: .top)
                        .opacity(ui.contentVisible ? 1 : 0)
                        .scaleEffect(ui.contentVisible || reduceMotion ? 1 : 0.96, anchor: .top)
                        .blur(radius: ui.contentVisible || reduceMotion ? 0 : 6)
                        .allowsHitTesting(ui.isOpen && ui.contentVisible)
                        .environment(\.colorScheme, .dark)
                        // Only the mask animates with the morph; the content's layout is fixed.
                        .mask(alignment: .top) {
                            shape.frame(width: shapeSize.width, height: shapeSize.height)
                        }
                        .accessibilityHidden(!ui.isOpen)
                }
                if !ui.isOpen {
                    if ui.activity == .none { closedBadge } else { ActivityView(ui: ui).frame(width: shapeSize.width, height: shapeSize.height) }
                }
                if ui.size == .compact || ui.size == .expanded {
                    resizeHandles.frame(width: shapeSize.width, height: shapeSize.height)
                }
            }
            .frame(width: max(shapeSize.width, ui.isOpen ? ui.contentSize.width : 0),
                   height: max(shapeSize.height, ui.isOpen ? ui.contentSize.height : 0), alignment: .top)
            .contentShape(shape.size(shapeSize))
            .onTapGesture { if !ui.isOpen { controller.open(.compact, focus: true) } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("sidekick")
    }

    private var shape: NotchShape {
        NotchShape(ear: NotchUIState.ear, radius: ui.cornerRadius)
    }

    @ViewBuilder private var content: some View {
        switch ui.size {
        case .peek: controller.content().environment(\.notchPeek, true)
        default: controller.content()
        }
    }

    /// Tiny buddy face peeking at the edge, with an unread dot.
    @ViewBuilder private var closedBadge: some View {
        HStack {
            Spacer()
            UnreadDot(count: ui.unread)
                .padding(.trailing, 10)
                .padding(.top, ui.notch.height / 2 - 3)
        }
        .frame(width: ui.notch.width, height: ui.notch.height, alignment: .top)
    }

    /// Drag the edges, or the visible grips in the bottom corners, to resize; double-click resets.
    private var resizeHandles: some View {
        ZStack {
            HStack {
                edge(horizontal: -1, vertical: 0).frame(width: 8)
                Spacer()
                edge(horizontal: 1, vertical: 0).frame(width: 8)
            }
            VStack {
                Spacer()
                edge(horizontal: 0, vertical: 1).frame(height: 8)
            }
            VStack {
                Spacer()
                HStack {
                    edge(horizontal: -1, vertical: 1).frame(width: 22, height: 22).overlay(ResizeGrip(mirrored: true))
                    Spacer()
                    edge(horizontal: 1, vertical: 1).frame(width: 22, height: 22).overlay(ResizeGrip(mirrored: false))
                }
            }
        }
        .padding(.top, ui.notch.height)
    }

    private func edge(horizontal: CGFloat, vertical: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                let c: NSCursor = horizontal != 0 && vertical != 0 ? .crosshair : horizontal != 0 ? .resizeLeftRight : .resizeUpDown
                if inside { c.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    // Measure in screen coordinates from where the drag began: the panel itself moves while
                    // it resizes, so view-relative translations would drift.
                    let m = NSEvent.mouseLocation
                    if dragStart == nil { dragStart = ui.targetSize; dragMouse = m }
                    guard let start = dragStart, let m0 = dragMouse else { return }
                    // Panel is centered under the notch, so horizontal drags grow both sides.
                    let d = CGSize(width: horizontal * (m.x - m0.x) * 2, height: vertical * (m0.y - m.y))
                    controller.resize(by: d, from: start)
                }
                .onEnded { _ in dragStart = nil; dragMouse = nil })
            .onTapGesture(count: 2) { controller.resetSize() }
            .help("drag to resize · double-click to reset")
    }
}

/// Three short diagonal lines in a bottom corner, so it's obvious the panel can be resized.
private struct ResizeGrip: View {
    let mirrored: Bool
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<3 {
                let o = CGFloat(i) * 4 + 4
                var p = Path()
                p.move(to: CGPoint(x: size.width - 5, y: size.height - 5 - o))
                p.addLine(to: CGPoint(x: size.width - 5 - o, y: size.height - 5))
                ctx.stroke(p, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        .allowsHitTesting(false)
    }
}

private struct UnreadDot: View {
    let count: Int
    private var unread: Int { count }
    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.33, blue: 0.52))
            .frame(width: 6, height: 6)
            .opacity(unread > 0 ? 1 : 0)
            .accessibilityLabel("\(unread) unread")
    }
}

private struct PeekKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var notchPeek: Bool {
        get { self[PeekKey.self] }
        set { self[PeekKey.self] = newValue }
    }
}

/// Notch body with flared "ears": the top corners curve outward into the screen edge, bottom corners round in.
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4), rad = min(radius, (r.height - e) / 1.2, (r.width - 2 * e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + rad, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - rad), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Live activity in the closed notch: label on the left, animated indicator + colored glow on the right.
private struct ActivityView: View {
    let ui: NotchUIState

    var body: some View {
        if case .message(let m) = ui.activity { message(m) } else { live }
    }

    /// Below the notch, centered, up to two lines — never under the camera.
    private func message(_ m: String) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: ui.notch.height)
            Text(m)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(NotchShape(ear: NotchUIState.ear, radius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(m)
    }

    private var live: some View {
        let a = ui.activity
        return HStack(spacing: 0) {
            Text(a.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, 18 + NotchUIState.ear)
                .transition(.opacity)
                .id(a.label)
            Spacer(minLength: 8)
            indicator(a)
                .padding(.trailing, 16 + NotchUIState.ear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Soft colored glow fading in from the right end.
            RadialGradient(colors: [a.tint.opacity(0.65), a.tint.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.97, y: 0.55), startRadius: 2, endRadius: 95)
                .allowsHitTesting(false)
        }
        .clipShape(NotchShape(ear: NotchUIState.ear, radius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a.label)
    }

    @ViewBuilder private func indicator(_ a: NotchUIState.Activity) -> some View {
        switch a {
        case .listening, .dictating: LevelBars(level: ui.activityLevel, color: a.tint)
        case .speaking: TalkingBars(color: a.tint)
        case .thinking, .working: PulsingDots(color: a.tint)
        default: EmptyView()
        }
    }
}

private struct LevelBars: View {
    let level: Float
    let color: Color
    private let weights: [CGFloat] = [0.5, 0.85, 1.0, 0.7]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: 2.5, height: max(4, min(14, 4 + CGFloat(level) * 26 * weights[i])))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .frame(height: 14)
    }
}

private struct TalkingBars: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(color).frame(width: 2.5, height: 5 + 9 * abs(sin(t * 7 + Double(i) * 1.1)))
                }
            }
            .frame(height: 14)
        }
    }
}

private struct PulsingDots: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.9)))
                }
            }
        }
    }
}
