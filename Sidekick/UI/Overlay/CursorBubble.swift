import AppKit
import SwiftUI

/// Click-through, non-activating bubble near the cursor (Phase 1 stand-in for the buddy overlay).
@MainActor
final class CursorBubble {
    private let panel: NSPanel
    private let state: AppState
    static let size = CGSize(width: 340, height: 150)
    /// When false, the bubble stays hidden (status is shown in the notch instead).
    var enabled: () -> Bool = { true }

    init(state: AppState) {
        self.state = state
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = DebugFlags.capturable ? .readOnly : .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BubbleView(state: state))
        host.frame = CGRect(origin: .zero, size: Self.size)
        panel.contentView = host
    }

    /// Shows the bubble beside the buddy anchor (global AppKit point).
    func show(near anchor: CGPoint) {
        state.bubbleVisible = true
        guard enabled() else { panel.orderOut(nil); return }
        place(anchor: anchor, duration: 0)
        panel.orderFrontRegardless()
        state.bubbleVisible = true
    }

    /// Keeps the bubble next to the buddy as it moves.
    func place(anchor: CGPoint, duration: TimeInterval) {
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        // Right of the buddy, top-aligned with it.
        var origin = CGPoint(x: anchor.x + 34, y: anchor.y - Self.size.height + 4)
        if origin.x + Self.size.width > vf.maxX { origin.x = anchor.x - 10 - Self.size.width }
        origin.x = max(vf.minX, origin.x)
        origin.y = min(max(vf.minY, origin.y), vf.maxY - Self.size.height)
        if duration > 0, panel.isVisible, !Motion.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    func hide() {
        state.bubbleVisible = false
        // Let the SwiftUI fade finish before ordering out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.state.bubbleVisible else { return }
            self.panel.orderOut(nil)
        }
    }
}

private struct BubbleView: View {
    let state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                BuddyDot(phase: state.phase, level: state.level)
                VStack(alignment: .leading, spacing: 4) {
                    if let step = state.stepLabel {
                        Text(step)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color(red: 1, green: 0.33, blue: 0.52)))
                    }
                    if !state.transcript.isEmpty {
                        Text(state.transcript)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if let note = state.modelNote, state.phase != .listening {
                        Label(note, systemImage: "bolt.horizontal.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("model: \(note)")
                    }
                    Text(mainLine)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(nil, value: mainLine)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            Spacer(minLength: 0)
        }
        .frame(width: CursorBubble.size.width, height: CursorBubble.size.height, alignment: .topLeading)
        .opacity(state.bubbleVisible ? 1 : 0)
        .scaleEffect(state.bubbleVisible || reduceMotion ? 1 : 0.96, anchor: .topLeading)
        .animation(.easeOut(duration: state.bubbleVisible ? 0.22 : 0.12), value: state.bubbleVisible)
        .accessibilityElement(children: .combine)
    }

    private var mainLine: String {
        switch state.phase {
        case .listening: "listening…"
        case .transcribing: "got it…"
        case .thinking: state.reply.isEmpty ? "thinking…" : state.reply
        case .speaking, .idle: state.reply.isEmpty ? " " : state.reply
        case .message(let m): m
        }
    }
}

/// Tiny original buddy: a rounded blob whose ring reacts to the phase.
private struct BuddyDot: View {
    let phase: TalkPhase
    let level: Float

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.55, blue: 1.0), Color(red: 0.7, green: 0.45, blue: 1.0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                .frame(width: 22, height: 22)
                .scaleEffect(phase == .listening ? 1 + CGFloat(level) * 0.6 : 1)
                .opacity(phase == .listening ? 1 : 0)
                .animation(.easeOut(duration: 0.08), value: level)
            if phase == .thinking || phase == .transcribing {
                ProgressView().controlSize(.mini).tint(.white)
            }
        }
        .frame(width: 30, height: 30)
    }
}
