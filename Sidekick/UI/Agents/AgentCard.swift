import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Top-right card showing an agent run. Non-activating; becomes key only to type a reply.
@MainActor
final class AgentCardController {
    private let panel: NSPanel
    private let runner: AgentRunner
    static let size = CGSize(width: 340, height: 420)

    init(runner: AgentRunner, followUp: @escaping (String) -> Void) {
        self.runner = runner
        panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: AgentCardView(runner: runner, close: { [weak self] in self?.hide() }, followUp: followUp))
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: vf.maxX - Self.size.width - 12, y: vf.maxY - Self.size.height - 8))
        panel.orderFrontRegardless()
    }

    func hide() {
        if runner.isActive { runner.cancel() }
        panel.orderOut(nil)
    }

    /// Closes the card but lets the task keep running (quiet runs, once the user has answered).
    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct AgentCardView: View {
    let runner: AgentRunner
    @AppStorage("talkSymbols") private var talkSymbols = "⌃⌥"
    let close: () -> Void
    let followUp: (String) -> Void
    @State private var appeared = false
    @State private var reply = ""
    @State private var bounce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch runner.status {
            case .countdown(let s):
                HStack {
                    Text("starting in \(s)…").font(.system(size: 12)).foregroundStyle(.secondary).contentTransition(.numericText())
                    Spacer()
                    Button("cancel") { runner.cancel() }.keyboardShortcut(.cancelAction)
                }
            case .needsApproval(let what):
                VStack(alignment: .leading, spacing: 6) {
                    Text("allow this?").font(.system(size: 12, weight: .semibold))
                    Text(what).font(.system(size: 11.5, design: .monospaced)).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                    HStack {
                        Button("don't") { runner.approve(false) }
                        Spacer()
                        Button("allow") { runner.approve(true) }.keyboardShortcut(.defaultAction)
                    }
                    Text("or just say \"yes\" / \"no\" with \(talkSymbols)").font(.caption2).foregroundStyle(.secondary)
                }
            case .asking(let q):
                VStack(alignment: .leading, spacing: 6) {
                    Text(q).font(.system(size: 12.5, weight: .medium))
                    HStack {
                        TextField("your answer", text: $reply).textFieldStyle(.roundedBorder).onSubmit(sendReply)
                        Button("send", action: sendReply).disabled(reply.isEmpty)
                    }
                }
            case .done(let summary), .failed(let summary):
                Text(summary).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
            if !runner.steps.isEmpty { stepList }
            if !runner.files.isEmpty { fileList }
            if case .done = runner.status { followUpBox }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: AgentCardController.size.width, height: AgentCardController.size.height, alignment: .top)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .scaleEffect(bounce ? 1.03 : 1)
        .offset(x: appeared ? 0 : 40, y: appeared ? 0 : -20)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Motion.smooth) { appeared = true } }
        .onChange(of: runner.status) { _, s in
            if case .done = s, !Motion.reduceMotion {
                withAnimation(Motion.bouncy) { bounce = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(Motion.bouncy) { bounce = false } }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: statusIcon).foregroundStyle(statusColor).font(.system(size: 14, weight: .semibold))
                .symbolEffect(.pulse, isActive: runner.status == .running)
            Text(runner.task).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("close agent card")
        }
    }

    private var statusIcon: String {
        switch runner.status {
        case .done: "checkmark.circle.fill"
        case .failed, .cancelled: "exclamationmark.circle.fill"
        case .needsApproval, .asking: "hand.raised.fill"
        default: "gearshape.2.fill"
        }
    }

    private var statusColor: Color {
        switch runner.status {
        case .done: .green
        case .failed, .cancelled: .orange
        case .needsApproval, .asking: .yellow
        default: Color(red: 0.62, green: 0.5, blue: 1)
        }
    }

    private var stepList: some View {
        DisclosureGroup(isExpanded: Binding(get: { runner.stepsExpanded }, set: { runner.stepsExpanded = $0 })) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(runner.steps) { step in
                        HStack(spacing: 6) {
                            Group {
                                switch step.state {
                                case .running: ProgressView().controlSize(.mini)
                                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                                case .declined: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 14)
                            .transition(.scale.combined(with: .opacity))
                            Text(step.title).font(.system(size: 11.5)).lineLimit(2)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        } label: {
            Text("\(runner.steps.count) step\(runner.steps.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("files").font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(runner.files, id: \.self) { url in FileTile(url: url) }
                }
            }
        }
    }

    private var followUpBox: some View {
        HStack {
            TextField("follow up…", text: $reply).textFieldStyle(.roundedBorder).onSubmit { sendFollowUp() }
            Button { sendFollowUp() } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.borderless).disabled(reply.isEmpty)
        }
    }

    private func sendReply() {
        guard !reply.isEmpty else { return }
        runner.reply(reply)
        reply = ""
    }

    private func sendFollowUp() {
        guard !reply.isEmpty else { return }
        followUp(reply)
        reply = ""
    }
}

/// QuickLook thumbnail; click opens, drag out to other apps.
private struct FileTile: View {
    let url: URL
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let thumb { Image(nsImage: thumb).resizable().scaledToFit() }
                else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit() }
            }
            .frame(width: 56, height: 56)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1).frame(width: 72)
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
        .task {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { thumb = rep.nsImage }
        }
        .accessibilityLabel("file \(url.lastPathComponent)")
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
