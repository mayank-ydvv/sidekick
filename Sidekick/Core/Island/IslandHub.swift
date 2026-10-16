import AppKit
import Observation
import SwiftUI

/// Something ongoing that lives in the island (iPhone "Live Activity").
enum IslandLive: Equatable, Identifiable {
    case call(app: String, since: Date)
    case timer(TimerStore.Timer)
    case stopwatch(start: Date, accumulated: TimeInterval, running: Bool)
    case meeting(title: String, start: Date, joinURL: URL?)
    case recording
    case media

    var id: String {
        switch self {
        case .call: "call"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .meeting: "meeting"
        case .recording: "recording"
        case .media: "media"
        }
    }
}

/// A short system alert (iPhone: AirPods connected, charging, silent mode…), shown for a few seconds.
struct IslandAlert: Equatable, Identifiable {
    enum Kind: Equatable {
        case volume(level: Float, muted: Bool)
        case brightness(level: Float)
        case charging(percent: Int, charging: Bool)
        case lowBattery(percent: Int)
        case bluetooth(name: String, symbol: String, battery: Int?, connected: Bool)
        case focus(name: String, on: Bool)
        case privacy(camera: Bool, on: Bool)
        case timerDone(label: String)
        case meetingNow(title: String, joinURL: URL?)
        case shelf(count: Int)
    }
    let id = UUID()
    var kind: Kind
    var duration: TimeInterval

    static func == (a: IslandAlert, b: IslandAlert) -> Bool { a.id == b.id && a.kind == b.kind }
}

/// Collects every island source and decides what the closed notch shows:
/// Sidekick's own activity (handled by the notch) > a system alert > a call > timer > meeting > recording > music.
@MainActor
@Observable
final class IslandHub {
    let nowPlaying = NowPlayingService()
    let timers = TimerStore()
    let shelf = FileShelf()
    private(set) var alert: IslandAlert?
    private(set) var call: (app: String, since: Date)?
    private(set) var meeting: (title: String, start: Date, joinURL: URL?)?
    private(set) var recording = false
    /// A drag with files is hovering the notch (shows the shelf drop zone).
    var dragActive = false

    private var alertWork: DispatchWorkItem?
    private var settings: AppSettings?

    func start(settings: AppSettings) {
        self.settings = settings
        if settings.data.islandMedia { nowPlaying.start() }
        timers.onFinished = { [weak self] t in
            self?.show(.init(kind: .timerDone(label: t.label), duration: 8))
            NSSound(named: "Glass")?.play()
        }
    }

    func stop() { nowPlaying.stop() }

    // MARK: Inputs from watchers

    func show(_ a: IslandAlert) {
        guard enabled(a.kind) else { return }
        withAnimation(Motion.snappy) { alert = a }
        alertWork?.cancel()
        let id = a.id
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.alert?.id == id else { return }
            withAnimation(Motion.smooth) { self.alert = nil }
        }
        alertWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + a.duration, execute: w)
    }

    func dismissAlert() {
        alertWork?.cancel()
        withAnimation(Motion.smooth) { alert = nil }
    }

    func setCall(_ c: (app: String, since: Date)?) {
        guard settings?.data.islandSystem ?? true else { call = nil; return }
        if c?.app != call?.app { withAnimation(Motion.smooth) { call = c } }
    }

    func setMeeting(_ m: (title: String, start: Date, joinURL: URL?)?) {
        guard settings?.data.islandTimers ?? true else { meeting = nil; return }
        if m?.title != meeting?.title || m?.start != meeting?.start { withAnimation(Motion.smooth) { meeting = m } }
    }

    func setRecording(_ on: Bool) {
        guard settings?.data.islandSystem ?? true else { recording = false; return }
        if on != recording { withAnimation(Motion.smooth) { recording = on } }
    }

    private func enabled(_ k: IslandAlert.Kind) -> Bool {
        guard let d = settings?.data else { return true }
        switch k {
        case .volume, .brightness, .bluetooth: return d.islandMedia
        case .charging, .lowBattery, .focus, .privacy: return d.islandSystem
        case .timerDone, .meetingNow: return d.islandTimers
        case .shelf: return d.islandShelf
        }
    }

    // MARK: Output

    /// Ongoing activities, most important first (hover cards show all of them).
    var live: [IslandLive] {
        var out: [IslandLive] = []
        if let c = call { out.append(.call(app: c.app, since: c.since)) }
        if let t = timers.timer { out.append(.timer(t)) }
        if let s = timers.stopwatch { out.append(.stopwatch(start: s.start, accumulated: s.accumulated, running: s.running)) }
        if let m = meeting { out.append(.meeting(title: m.title, start: m.start, joinURL: m.joinURL)) }
        if recording { out.append(.recording) }
        if nowPlaying.track != nil { out.append(.media) }
        return out
    }

    /// What the closed notch shows when Sidekick itself is idle. Paused music only shows for a short while.
    var closedItem: IslandLive? {
        live.first { item in
            if case .media = item { return nowPlaying.showInClosedNotch }
            return true
        }
    }

    /// Hover shows island cards instead of the chat preview when there's something live (or files to drop).
    var hasCards: Bool { !live.isEmpty || !shelf.items.isEmpty || dragActive }

    /// Hover panel size for the current cards (content starts below the notch).
    func peekSize(notchHeight: CGFloat) -> CGSize {
        var heights: [CGFloat] = live.prefix(3).map { item in
            if case .media = item { return 132 }
            return 58
        }
        if !shelf.items.isEmpty || dragActive { heights.append(76) }
        let cards = heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 8
        // notch + top padding + cards + spacing + "chat" row + bottom padding
        return CGSize(width: 450, height: max(150, notchHeight + 6 + cards + 8 + 22 + 10))
    }
}
