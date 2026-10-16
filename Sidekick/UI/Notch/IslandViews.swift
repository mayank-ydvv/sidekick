import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// iPhone-style colours.
enum IslandColor {
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let purple = Color(red: 0.37, green: 0.36, blue: 0.9)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
}

/// How the closed island is laid out around the camera notch.
enum IslandLayout: Equatable {
    /// Content on both sides of the notch (iPhone "compact": leading + trailing).
    case sides
    /// A strip of the given height under the notch for text (names, buttons).
    case strip(CGFloat)
}

extension IslandHub {
    /// nil = plain notch.
    var closedLayout: IslandLayout? {
        if let a = alert {
            switch a.kind {
            case .bluetooth, .focus, .timerDone, .meetingNow, .shelf: return .strip(44)
            default: return .sides
            }
        }
        return closedItem == nil ? nil : .sides
    }
}

// MARK: - Closed island

/// What the closed notch shows for island activity: leading content left of the camera, trailing right of it,
/// or a strip below it. Nothing is ever drawn under the camera itself.
struct IslandClosedView: View {
    let hub: IslandHub
    let ui: NotchUIState

    var body: some View {
        let layout = ui.islandLayout
        let visible = ui.islandContentVisible
        Group {
            if case .strip = layout, let a = ui.islandAlert {
                VStack(spacing: 0) {
                    Color.clear.frame(height: ui.notch.height)
                    strip(a.kind).padding(.horizontal, 18).frame(maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    leading.frame(width: sideWidth, alignment: .center)
                    Spacer(minLength: 0)
                    trailing.frame(width: sideWidth, alignment: .center)
                }
                .frame(height: ui.notch.height)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Content eases in after the shape has grown (and out before it shrinks).
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.82)
        .blur(radius: visible ? 0 : 5)
        .clipShape(NotchShape(ear: NotchUIState.ear, radius: layout == .sides ? 10 : 14))
        .transition(.opacity)
        .id(identity)
        .accessibilityElement(children: .combine)
    }

    private var identity: String {
        if let a = ui.islandAlert { return a.id.uuidString }
        return ui.islandItem?.id ?? "none"
    }

    /// Room on each side of the camera (the shape is wider than the notch by this much on both sides).
    private var sideWidth: CGFloat { max(30, (NotchUIState.activityWidth - ui.notch.width) / 2 - NotchUIState.ear) }

    @ViewBuilder private var leading: some View {
        if let a = ui.islandAlert {
            alertLeading(a.kind)
        } else if let item = ui.islandItem {
            switch item {
            case .media: MediaArt(track: hub.nowPlaying.track, size: 20, radius: 5)
            case .timer: Image(systemName: "timer").foregroundStyle(IslandColor.orange).font(.system(size: 14, weight: .semibold))
            case .stopwatch: Image(systemName: "stopwatch").foregroundStyle(IslandColor.orange).font(.system(size: 14, weight: .semibold))
            case .call: Image(systemName: "phone.fill").foregroundStyle(IslandColor.green).font(.system(size: 13, weight: .semibold))
            case .meeting: Image(systemName: "calendar").foregroundStyle(IslandColor.red).font(.system(size: 14, weight: .semibold))
            case .recording: PulsingDot(color: IslandColor.red)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if let a = ui.islandAlert {
            alertTrailing(a.kind)
        } else if let item = ui.islandItem {
            switch item {
            case .media:
                if let t = hub.nowPlaying.track { MusicBars(color: Color(nsColor: t.tint), playing: t.playing) }
            case .timer(let t):
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(TimerStore.clock(t.remaining())).foregroundStyle(IslandColor.orange)
                }.font(.system(size: 13, weight: .semibold).monospacedDigit())
            case .stopwatch:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(TimerStore.clock(hub.timers.stopwatch?.elapsed() ?? 0)).foregroundStyle(IslandColor.orange)
                }.font(.system(size: 13, weight: .semibold).monospacedDigit())
            case .call(_, let since):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(TimerStore.clock(ctx.date.timeIntervalSince(since))).foregroundStyle(IslandColor.green)
                }.font(.system(size: 13, weight: .semibold).monospacedDigit())
            case .meeting(_, let start, _):
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text("\(max(1, Int(ceil(start.timeIntervalSince(ctx.date) / 60)))) min").foregroundStyle(IslandColor.red)
                }.font(.system(size: 12, weight: .semibold).monospacedDigit())
            case .recording:
                Text("REC").font(.system(size: 11, weight: .bold)).foregroundStyle(IslandColor.red)
            }
        }
    }

    @ViewBuilder private func alertLeading(_ k: IslandAlert.Kind) -> some View {
        switch k {
        case .volume(let v, let muted):
            Image(systemName: muted || v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                .foregroundStyle(.white).font(.system(size: 13, weight: .semibold))
        case .brightness(let v):
            Image(systemName: v < 0.5 ? "sun.min.fill" : "sun.max.fill").foregroundStyle(.white).font(.system(size: 14, weight: .semibold))
        case .charging(_, let charging):
            Image(systemName: charging ? "battery.100percent.bolt" : "battery.75percent")
                .symbolRenderingMode(.palette).foregroundStyle(charging ? IslandColor.green : .white, .white.opacity(0.5))
                .font(.system(size: 15))
        case .lowBattery:
            Image(systemName: "battery.25percent").symbolRenderingMode(.palette).foregroundStyle(IslandColor.red, .white.opacity(0.5)).font(.system(size: 15))
        case .privacy(let camera, _):
            Image(systemName: camera ? "video.fill" : "mic.fill").foregroundStyle(camera ? IslandColor.green : IslandColor.orange)
                .font(.system(size: 12, weight: .semibold))
        default: EmptyView()
        }
    }

    @ViewBuilder private func alertTrailing(_ k: IslandAlert.Kind) -> some View {
        switch k {
        case .volume(let v, let muted): LevelBar(level: muted ? 0 : v)
        case .brightness(let v): LevelBar(level: v)
        case .charging(let p, let charging):
            Text("\(p)%").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(charging ? IslandColor.green : .white)
        case .lowBattery(let p):
            Text("\(p)%").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(IslandColor.red)
        case .privacy(let camera, _):
            Circle().fill(camera ? IslandColor.green : IslandColor.orange).frame(width: 7, height: 7)
        default: EmptyView()
        }
    }

    @ViewBuilder private func strip(_ k: IslandAlert.Kind) -> some View {
        HStack(spacing: 10) {
            switch k {
            case .bluetooth(let name, let symbol, let battery, let connected):
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(connected ? "Connected" : "Disconnected").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let battery {
                    Text("\(battery)%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(battery <= 20 ? IslandColor.red : IslandColor.green)
                }
            case .focus(let name, let on):
                Image(systemName: Self.focusSymbol(name)).foregroundStyle(IslandColor.purple).font(.system(size: 16))
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                Text(on ? "On" : "Off").font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? IslandColor.purple : .secondary)
            case .timerDone(let label):
                Image(systemName: "timer").foregroundStyle(IslandColor.orange).font(.system(size: 16, weight: .semibold))
                Text("Timer done").font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Button("Stop") { hub.dismissAlert() }.buttonStyle(IslandPillButton(color: IslandColor.orange))
            case .meetingNow(let title, let url):
                Image(systemName: "calendar").foregroundStyle(IslandColor.red).font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Starting now").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let url {
                    Button("Join") { NSWorkspace.shared.open(url); hub.dismissAlert() }.buttonStyle(IslandPillButton(color: IslandColor.green))
                }
            case .shelf(let count):
                Image(systemName: "tray.full.fill").foregroundStyle(IslandColor.blue).font(.system(size: 15))
                Text(count == 1 ? "1 file on the shelf" : "\(count) files on the shelf").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
            default: EmptyView()
            }
        }
        .foregroundStyle(.white)
    }

    static func focusSymbol(_ name: String) -> String {
        switch name {
        case "Sleep": "bed.double.fill"
        case "Work": "briefcase.fill"
        case "Personal": "person.fill"
        case "Driving": "car.fill"
        default: "moon.fill"
        }
    }
}

// MARK: - Hover cards (iPhone "expanded")

struct IslandCardsView: View {
    let hub: IslandHub
    let openChat: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(hub.live.prefix(3)) { item in
                card(item)
            }
            if !hub.shelf.items.isEmpty || hub.dragActive { ShelfCard(shelf: hub.shelf, dropping: hub.dragActive) }
            Spacer(minLength: 0)
            Button(action: openChat) {
                Label("Chat with Sidekick", systemImage: "bubble.left.fill").font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
        .foregroundStyle(.white)
    }

    @ViewBuilder private func card(_ item: IslandLive) -> some View {
        switch item {
        case .media: MediaCard(np: hub.nowPlaying)
        case .timer(let t): TimerCard(store: hub.timers, timer: t)
        case .stopwatch: StopwatchCard(store: hub.timers)
        case .call(let app, let since):
            InfoCard(symbol: "phone.fill", color: IslandColor.green, title: "\(app) call",
                     subtitle: { d in TimerStore.clock(d.timeIntervalSince(since)) })
        case .meeting(let title, let start, let url):
            InfoCard(symbol: "calendar", color: IslandColor.red, title: title,
                     subtitle: { d in "Starts in \(max(1, Int(ceil(start.timeIntervalSince(d) / 60)))) min" }) {
                if let url { Button("Join") { NSWorkspace.shared.open(url) }.buttonStyle(IslandPillButton(color: IslandColor.green)) }
            }
        case .recording:
            InfoCard(symbol: "record.circle", color: IslandColor.red, title: "Screen recording", subtitle: { _ in "Recording your screen" }) {
                Button("Stop") {
                    // ⌘⌃Esc stops a ⇧⌘5 screen recording.
                    Task { await TextInserter.keystroke(53, [.maskCommand, .maskControl]) }
                }.buttonStyle(IslandPillButton(color: IslandColor.red))
            }
        }
    }
}

private struct MediaCard: View {
    let np: NowPlayingService

    var body: some View {
        if let t = np.track {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    MediaArt(track: t, size: 52, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(t.artist.isEmpty ? (t.album.isEmpty ? " " : t.album) : t.artist)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let id = t.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            .help("Open \(url.deletingPathExtension().lastPathComponent)")
                            .onTapGesture { np.openSourceApp() }
                    }
                    MusicBars(color: Color(nsColor: t.tint), playing: t.playing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { np.openSourceApp() }
                if t.duration > 0 { Scrubber(track: t) { np.seek(to: $0) } }
                HStack(spacing: 34) {
                    controlButton("backward.fill", size: 16) { np.send(.previous) }
                    controlButton(t.playing ? "pause.fill" : "play.fill", size: 22) { np.togglePlayPause() }
                    controlButton("forward.fill", size: 16) { np.send(.next) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Scrubber: View {
    let track: NowPlayingService.Track
    let seek: (TimeInterval) -> Void
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pos = dragging.map { $0 * track.duration } ?? track.position(at: ctx.date)
            HStack(spacing: 8) {
                Text(TimerStore.clock(pos)).frame(width: 40, alignment: .trailing)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: max(4, g.size.width * pos / max(1, track.duration)))
                    }
                    .frame(height: dragging == nil ? 5 : 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragging = min(1, max(0, v.location.x / g.size.width)) }
                        .onEnded { _ in if let d = dragging { seek(d * track.duration) }; dragging = nil })
                }
                .frame(height: 14)
                Text("-" + TimerStore.clock(max(0, track.duration - pos))).frame(width: 44, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

private struct TimerCard: View {
    let store: TimerStore
    let timer: TimerStore.Timer

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ZStack {
                    Circle().stroke(IslandColor.orange.opacity(0.25), lineWidth: 4)
                    Circle().trim(from: 0, to: 1 - timer.progress).stroke(IslandColor.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(timer.label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(TimerStore.clock(timer.remaining())).font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(IslandColor.orange)
                }
            }
            Spacer()
            roundButton(timer.running ? "pause.fill" : "play.fill", IslandColor.orange) {
                timer.running ? store.pauseTimer() : store.resumeTimer()
            }
            roundButton("plus", .white) { store.addMinute() }.help("+1 minute")
            roundButton("xmark", .white) { store.cancelTimer() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }
}

private struct StopwatchCard: View {
    let store: TimerStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "stopwatch").font(.system(size: 20, weight: .semibold)).foregroundStyle(IslandColor.orange).frame(width: 30)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(Self.format(store.stopwatch?.elapsed() ?? 0)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(IslandColor.orange)
            }
            Spacer()
            let running = store.stopwatch?.running ?? false
            roundButton(running ? "pause.fill" : "play.fill", IslandColor.orange) { running ? store.stopwatchPause() : store.stopwatchStart() }
            roundButton("xmark", .white) { store.stopwatchReset() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }

    static func format(_ s: TimeInterval) -> String {
        let t = Int(s), tenths = Int((s - Double(t)) * 10)
        return String(format: "%d:%02d.%d", t / 60, t % 60, tenths)
    }
}

private struct InfoCard<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: (Date) -> String
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, color: Color, title: String, subtitle: @escaping (Date) -> String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.symbol = symbol; self.color = color; self.title = title; self.subtitle = subtitle; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(subtitle(ctx.date)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }
}

private struct ShelfCard: View {
    let shelf: FileShelf
    let dropping: Bool

    var body: some View {
        HStack(spacing: 10) {
            if shelf.items.isEmpty {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 18)).foregroundStyle(IslandColor.blue)
                Text("Drop files here to keep them handy").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items, id: \.self) { url in
                            VStack(spacing: 3) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 34, height: 34)
                                Text(url.lastPathComponent).font(.system(size: 9.5)).lineLimit(1).frame(width: 60)
                            }
                            .help(url.path)
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Remove from shelf") { shelf.remove(url) }
                            }
                        }
                    }
                }
                VStack(spacing: 6) {
                    Button { shelf.airDrop() } label: { Image(systemName: "airplayaudio").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.plain).help("AirDrop")
                    Button { shelf.clear() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.plain).help("Clear shelf")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(height: 76)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(dropping ? 0.12 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(IslandColor.blue.opacity(dropping ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        )
    }
}

// MARK: - Small pieces

struct MediaArt: View {
    let track: NowPlayingService.Track?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let img = track?.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if let id = track?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                ZStack { Color.white.opacity(0.12); Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Bars that bounce while music plays (flat when paused), tinted with the artwork colour.
struct MusicBars: View {
    let color: Color
    let playing: Bool
    private let speeds: [Double] = [5.1, 6.7, 4.3, 7.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let h = playing ? 4 + 10 * abs(sin(t * speeds[i] + Double(i) * 1.7)) : 3
                    Capsule().fill(color).frame(width: 2.8, height: h)
                }
            }
            .frame(height: 15)
        }
    }
}

private struct LevelBar: View {
    let level: Float
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.22))
            Capsule().fill(Color.white).frame(width: max(0, 44 * CGFloat(level)))
        }
        .frame(width: 44, height: 5)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9).opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
    }
}

struct IslandPillButton: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

@ViewBuilder
private func roundButton(_ symbol: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(color == .white ? .white : .black)
            .frame(width: 32, height: 32)
            .background(Circle().fill(color == .white ? Color.white.opacity(0.14) : color))
    }
    .buttonStyle(.plain)
}
