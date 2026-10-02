import AppKit
import CoreAudio

/// Silences voice and unprompted bubbles when the user is on a call, sharing their screen, or in Focus.
/// Event-driven: CoreAudio property listener + front-app change notifications (no polling).
@MainActor
final class QuietModeDetector {
    private(set) var isQuiet = false
    var onChange: ((Bool) -> Void)?
    /// True while Sidekick itself is using the mic (so our own capture isn't mistaken for a call).
    var ownMicActive: () -> Bool = { false }

    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime", "com.cisco.webexmeetingsapp",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.skype.skype", "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
    ]

    private var listenerDevice = AudioDeviceID(0)

    func start() {
        installMicListener()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    func evaluate() {
        // Another app holding the mic is treated as a call; known call apps are logged for context.
        let quiet = micInUseByOthers() || screenSharing() || focusOn()
        if quiet != isQuiet {
            isQuiet = quiet
            Log.app.info("quiet mode \(quiet ? "on" : "off", privacy: .public)")
            onChange?(quiet)
        }
    }

    // MARK: Signals

    private func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    /// "Is running somewhere" on the default input while we're not capturing ⇒ another app (a call) has the mic.
    private func micInUseByOthers() -> Bool {
        guard !ownMicActive(), let dev = defaultInput() else { return false }
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private func installMicListener() {
        guard let dev = defaultInput() else { return }
        listenerDevice = dev
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // Our own capture toggles this too; re-evaluate shortly after it settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.evaluate() }
            }
        }
    }

    /// Best effort: known screen-share overlays (Zoom/Meet/Teams share toolbars) or macOS Screen Sharing.
    private func screenSharing() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let name = (w[kCGWindowName as String] as? String ?? "").lowercased()
            if owner == "screensharingagent" || name.contains("you are screen sharing") || name.contains("is sharing your screen")
                || name.contains("stop share") || name.contains("zoom share") { return true }
        }
        return false
    }

    /// Best effort Focus/DND: the assertions file is readable only with Full Disk Access; otherwise assume off.
    private func focusOn() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let store = (json["data"] as? [[String: Any]])?.first,
              let records = store["storeAssertionRecords"] as? [Any] else { return false }
        return !records.isEmpty
    }
}

/// Opt-in proactive suggestions: morning (and optional afternoon) runs; back off when ignored.
/// 3 unopened days → pause 1 day, doubling up to 7 days.
struct ProactiveBackoff: Codable, Equatable {
    var unopenedDays = 0
    var pauseDays = 0
    var pausedUntil: Date?

    func shouldRun(on date: Date) -> Bool {
        guard let until = pausedUntil else { return true }
        return date >= until
    }

    /// Call once per delivery day with whether the user opened the cards.
    mutating func record(opened: Bool, on date: Date, calendar: Calendar = .current) {
        if opened {
            unopenedDays = 0
            pauseDays = 0
            pausedUntil = nil
            return
        }
        unopenedDays += 1
        if unopenedDays >= 3 {
            pauseDays = pauseDays == 0 ? 1 : min(7, pauseDays * 2)
            pausedUntil = calendar.date(byAdding: .day, value: pauseDays, to: calendar.startOfDay(for: date))
            unopenedDays = 0
        }
    }
}

/// Parses the model's suggestion output: one JSON array of {title, task}.
enum SuggestionParser {
    struct Card: Codable, Equatable, Identifiable {
        var id: String { title }
        var title: String
        var task: String
    }

    static func parse(_ text: String) -> [Card] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let cards = try? JSONDecoder().decode([Card].self, from: data) else { return [] }
        return Array(cards.filter { !$0.title.isEmpty && !$0.task.isEmpty }.prefix(2))
    }
}
