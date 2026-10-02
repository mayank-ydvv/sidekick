import CoreGraphics
import Foundation

/// Where the user should click for the current step (global AppKit coordinates).
struct TeachTarget: Equatable, Sendable {
    var point: CGPoint
    var frame: CGRect?
    var label: String?

    static let pointTolerance: CGFloat = 30
    static let framePadding: CGFloat = 6

    func isHit(_ click: CGPoint) -> Bool {
        if let frame, frame.insetBy(dx: -Self.framePadding, dy: -Self.framePadding).contains(click) { return true }
        return hypot(click.x - point.x, click.y - point.y) <= Self.pointTolerance
    }
}

/// Step-by-step tutor state machine: explain → point → waitClick → verify → next.
/// Pure logic; the coordinator drives it with model tags, clicks and voice commands.
struct TeachingSession: Equatable {
    enum Phase: Equatable { case inactive, explaining, waitingForClick, verifying }
    enum ClickResult: Equatable { case ignored, hit, miss(hints: Int) }
    enum Command: Equatable { case stop, skip, back }

    private(set) var phase: Phase = .inactive
    private(set) var step: Int?
    private(set) var total: Int?
    private(set) var target: TeachTarget?
    private(set) var misses = 0
    private var expectsClick = false

    var isActive: Bool { phase != .inactive }

    /// A new model reply is starting.
    mutating func replyStarted() {
        expectsClick = false
        if isActive { phase = .explaining }
        target = nil
    }

    mutating func onStep(n: Int, of: Int?) {
        step = n
        if let of { total = of }
        if phase == .inactive { phase = .explaining }
    }

    mutating func onTarget(_ t: TeachTarget) { target = t }

    mutating func onWaitClick() {
        expectsClick = true
        if phase == .inactive { phase = .explaining }
    }

    /// The reply finished streaming. Returns true if we should now wait for a click.
    mutating func replyFinished() -> Bool {
        guard isActive else { return false }
        if expectsClick, target != nil {
            phase = .waitingForClick
            misses = 0
            return true
        }
        // No click requested: the lesson is over (or this was just a normal answer).
        if !expectsClick { end() }
        return false
    }

    mutating func click(at p: CGPoint) -> ClickResult {
        guard phase == .waitingForClick, let target else { return .ignored }
        if target.isHit(p) {
            phase = .verifying
            return .hit
        }
        misses += 1
        return .miss(hints: misses)
    }

    mutating func end() {
        self = TeachingSession()
    }

    var stepLabel: String? {
        guard isActive, let step else { return nil }
        if let total { return "step \(step) of \(total)" }
        return "step \(step)"
    }

    /// Recognizes short spoken control commands during a lesson (English + Hinglish).
    static func command(from transcript: String) -> Command? {
        let t = transcript.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = t.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return nil }
        let joined = words.joined(separator: " ")
        let stop = ["stop", "stop it", "stop teaching", "cancel", "quit", "exit", "that's enough", "band karo", "ruk jao", "bas"]
        let skip = ["skip", "skip it", "skip this", "skip this step", "next", "next step", "aage", "aage chalo"]
        let back = ["go back", "back", "previous", "previous step", "undo", "peeche", "wapas"]
        if stop.contains(joined) { return .stop }
        if skip.contains(joined) { return .skip }
        if back.contains(joined) { return .back }
        return nil
    }
}
