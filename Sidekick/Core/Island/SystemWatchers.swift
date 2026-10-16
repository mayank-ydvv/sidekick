import AppKit
import AudioToolbox
import CoreAudio
import CoreMediaIO
import IOBluetooth
import IOKit.ps

/// Event-driven system signals for the island: power, volume, brightness, Bluetooth, mic/camera/calls,
/// screen recording and Focus. Nothing polls continuously.
@MainActor
final class SystemWatchers: NSObject {
    private weak var hub: IslandHub?
    private let settings: AppSettings
    /// True while Sidekick itself records (so our own mic use isn't reported as "mic on" / a call).
    var ownMicActive: () -> Bool = { false }
    private var started = Date()

    init(hub: IslandHub, settings: AppSettings) {
        self.hub = hub
        self.settings = settings
    }

    func start() {
        started = Date()
        startPower()
        startVolume()
        startBluetooth()
        startPrivacy()
        startRecordingWatch()
        startFocus()
    }

    // MARK: Power

    private var lastPower: (charging: Bool, percent: Int)?
    private var powerSource: CFRunLoopSource?

    private func startPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemWatchers>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.powerChanged() }
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        lastPower = Self.battery()
    }

    nonisolated static func battery() -> (charging: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cap = d[kIOPSCurrentCapacityKey] as? Int ?? 0, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (onAC, max > 0 ? Int((Double(cap) / Double(max) * 100).rounded()) : cap)
        }
        return nil
    }

    private func powerChanged() {
        guard let now = Self.battery() else { return }
        defer { lastPower = now }
        guard let before = lastPower else { return }
        if now.charging != before.charging {
            hub?.show(.init(kind: .charging(percent: now.percent, charging: now.charging), duration: 3))
        } else if !now.charging, now.percent < before.percent, [20, 10, 5].contains(now.percent) {
            hub?.show(.init(kind: .lowBattery(percent: now.percent), duration: 5))
        }
    }

    // MARK: Volume

    private var outputDevice = AudioObjectID(0)
    private var lastVolume: (Float, Bool)?

    private func startVolume() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachOutput(announce: false) }
        }
        attachOutput(announce: false)
    }

    private func attachOutput(announce: Bool) {
        outputDevice = Self.defaultDevice(output: true) ?? 0
        guard outputDevice != 0 else { return }
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            let dev = outputDevice
            AudioObjectAddPropertyListenerBlock(dev, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.outputDevice == dev else { return }
                    self.volumeChanged()
                }
            }
        }
        lastVolume = Self.volume(outputDevice)
    }

    private func volumeChanged() {
        guard let v = Self.volume(outputDevice) else { return }
        if let last = lastVolume, abs(last.0 - v.0) < 0.001, last.1 == v.1 { return }
        lastVolume = v
        guard Date().timeIntervalSince(started) > 2 else { return }
        hub?.show(.init(kind: .volume(level: v.0, muted: v.1), duration: 1.6))
    }

    nonisolated static func defaultDevice(output: Bool) -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    nonisolated static func volume(_ dev: AudioObjectID) -> (Float, Bool)? {
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        var m = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyMute
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m)
        return (v, m != 0)
    }

    /// Volume / mute keys handled by Sidekick so the level shows in the notch instead of the system pop-up.
    /// Returns false (let macOS handle it) when the device's volume can't be set, e.g. some HDMI outputs.
    func handleVolumeKey(up: Bool?, fine: Bool) -> Bool {
        let dev = outputDevice != 0 ? outputDevice : (Self.defaultDevice(output: true) ?? 0)
        guard dev != 0, let (cur, muted) = Self.volume(dev) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
        func setMute(_ on: Bool) {
            var m: UInt32 = on ? 1 : 0
            AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
        guard let up else { setMute(!muted); return true }   // mute key
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        var v = Float32(min(1, max(0, (cur / step).rounded() * step + (up ? step : -step))))
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if muted, up { setMute(false) }
        if v == 0, !up { setMute(true) }
        return true
    }

    // MARK: Brightness (built-in display, via the private DisplayServices framework)

    private typealias GetB = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetB = @convention(c) (UInt32, Float) -> Int32
    private lazy var ds: (get: GetB, set: SetB)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(g, to: GetB.self), unsafeBitCast(s, to: SetB.self))
    }()

    private var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8), n = UInt32(0)
        CGGetActiveDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Returns false (macOS handles the key) if the built-in display's brightness can't be read/set.
    func handleBrightnessKey(up: Bool, fine: Bool) -> Bool {
        guard let ds, let d = builtInDisplay else { return false }
        var b: Float = 0
        guard ds.get(d, &b) == 0 else { return false }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let v = min(1, max(0, (b / step).rounded() * step + (up ? step : -step)))
        guard ds.set(d, v) == 0 else { return false }
        hub?.show(.init(kind: .brightness(level: v), duration: 1.6))
        return true
    }

    // MARK: Bluetooth

    private var connectNote: IOBluetoothUserNotification?
    private var lastAnnounced: [String: Date] = [:]
    private var announcedConnected = Set<String>()
    private var lastWake = Date.distantPast

    private func startBluetooth() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(btConnected(_:device:)))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastWake = Date() }
        }
    }

    enum BTKind: Equatable { case audio, peripheral, ignore }

    /// Which connections are worth an alert. Phones, watches, tablets and Macs connect silently all the time for
    /// Handoff/Continuity/Instant Hotspot, so they never are.
    nonisolated static func kind(major: UInt32, name: String) -> BTKind {
        let n = name.lowercased()
        if ["airpods", "beats", "buds", "headphone", "headset", "speaker", "earbuds", "soundcore", "jbl", "bose", "sony wh", "sony wf"]
            .contains(where: n.contains) { return .audio }
        switch major {
        case 0x04: return .audio                       // audio / video
        case 0x05: return .peripheral                  // keyboard, mouse, trackpad, game controller
        default: return .ignore                        // 0x01 computer, 0x02 phone, 0x07 wearable, 0x00 misc…
        }
    }

    @objc private func btConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(btDisconnected(_:device:)))
        let name = device.name ?? ""
        let kind = Self.kind(major: device.deviceClassMajor, name: name)
        // Already-connected devices are reported right after registering; only announce new connections.
        guard kind != .ignore, !name.isEmpty, Date().timeIntervalSince(started) > 10 else { return }
        // Keyboards/mice reconnect by themselves after the Mac wakes; that's not news.
        if kind == .peripheral, Date().timeIntervalSince(lastWake) < 15 { return }
        let key = device.addressString ?? name
        if let last = lastAnnounced[key], Date().timeIntervalSince(last) < 60 { return }
        // Only once it has actually stayed connected (filters out brief reconnect blips); battery arrives by then too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, device.isConnected() else { return }
            self.lastAnnounced[key] = Date()
            if kind == .audio { self.announcedConnected.insert(key) }
            self.hub?.show(.init(kind: .bluetooth(name: name, symbol: Self.symbol(for: device), battery: Self.battery(device),
                                                  connected: true), duration: 3.5))
        }
    }

    @objc private func btDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        let key = device.addressString ?? device.name ?? ""
        // Only for headphones/speakers we announced, and only if they stay disconnected.
        guard announcedConnected.contains(key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !device.isConnected(), self.announcedConnected.remove(key) != nil else { return }
            let name = device.name ?? "Bluetooth device"
            self.hub?.show(.init(kind: .bluetooth(name: name, symbol: Self.symbol(for: device), battery: nil, connected: false), duration: 2.5))
        }
    }

    static func symbol(for d: IOBluetoothDevice) -> String {
        let n = (d.name ?? "").lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if d.deviceClassMajor == 0x04 { return "headphones" }   // audio/video
        return "dot.radiowaves.left.and.right"
    }

    /// Battery % (AirPods & Beats expose it through private selectors; read them only if present).
    static func battery(_ d: IOBluetoothDevice) -> Int? {
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt8
        var values: [Int] = []
        for name in ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight"] {
            let sel = NSSelectorFromString(name)
            guard d.responds(to: sel), let imp = d.method(for: sel) else { continue }
            let v = Int(unsafeBitCast(imp, to: Fn.self)(d, sel))
            if v > 0, v <= 100 { values.append(v) }
            if name == "batteryPercentCombined" || name == "batteryPercentSingle", v > 0 { return v }
        }
        return values.min()
    }

    // MARK: Mic, camera, calls

    private var micOn = false, camOn = false
    private var micSince: Date?

    static let callApps: [String: String] = [
        "com.apple.FaceTime": "FaceTime", "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "net.whatsapp.WhatsApp": "WhatsApp", "com.hnc.Discord": "Discord", "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Webex", "com.skype.skype": "Skype", "com.apple.MobileSMS": "Messages",
    ]

    private func startPrivacy() {
        if let mic = Self.defaultDevice(output: false) {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(mic, &addr, .main) { [weak self] _, _ in
                // Our own capture toggles this too; evaluate after it settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { self?.evaluatePrivacy() } }
            }
        }
        for cam in Self.cameras() {
            var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            CMIOObjectAddPropertyListenerBlock(cam, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluatePrivacy() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluatePrivacy() }
        }
        evaluatePrivacy(announce: false)
    }

    nonisolated static func cameras() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size = UInt32(0)
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used = UInt32(0)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func running(camera id: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var v = UInt32(0), used = UInt32(0)
        return CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &v) == noErr && v != 0
    }

    nonisolated static func micRunning() -> Bool {
        guard let dev = defaultDevice(output: false) else { return false }
        var v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    private func evaluatePrivacy(announce: Bool = true) {
        let mic = Self.micRunning() && !ownMicActive()
        let cam = Self.cameras().contains { Self.running(camera: $0) }
        if cam != camOn {
            camOn = cam
            if cam, announce { hub?.show(.init(kind: .privacy(camera: true, on: true), duration: 2.5)) }
        }
        // Which apps are actually recording from the mic (not just running).
        let capturing = mic ? Self.inputBundleIDs() : []
        let call = mic ? Self.callApp(capturing: capturing) : nil
        if mic != micOn {
            micOn = mic
            micSince = mic ? Date() : nil
            if mic, announce, call == nil, !capturing.contains(Self.screenRecorder) {
                hub?.show(.init(kind: .privacy(camera: false, on: true), duration: 2.5))
            }
        }
        if let call { hub?.setCall((call, micSince ?? Date())) } else { hub?.setCall(nil) }
        // A screen recording with the microphone is a recording, not a call.
        if capturing.contains(Self.screenRecorder) { hub?.setRecording(true) }
    }

    nonisolated static let screenRecorder = "com.apple.screencaptureui"
    nonisolated static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                                    "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"]

    /// Bundle IDs of the processes currently recording audio input (CoreAudio process objects, macOS 14.4+).
    /// Helper processes are mapped to their app ("com.google.Chrome.helper" → "com.google.Chrome").
    nonisolated static func inputBundleIDs() -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let own = Bundle.main.bundleIdentifier
        var out: [String] = []
        for p in ids {
            var running = UInt32(0), sz = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(p, &a, 0, nil, &sz, &running) == noErr, running != 0 else { continue }
            var bid: Unmanaged<CFString>?
            sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            a.mSelector = kAudioProcessPropertyBundleID
            var id = ""
            if AudioObjectGetPropertyData(p, &a, 0, nil, &sz, &bid) == noErr, let b = bid?.takeRetainedValue() { id = b as String }
            if id.isEmpty {
                var pid = pid_t(0); sz = UInt32(MemoryLayout<pid_t>.size)
                a.mSelector = kAudioProcessPropertyPID
                if AudioObjectGetPropertyData(p, &a, 0, nil, &sz, &pid) == noErr {
                    id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                }
            }
            guard !id.isEmpty, id != own else { continue }
            out.append(appBundle(id))
        }
        return out
    }

    /// "com.google.Chrome.helper.renderer" → "com.google.Chrome", "us.zoom.xos.helper" → "us.zoom.xos".
    nonisolated static func appBundle(_ id: String) -> String {
        for app in Array(callApps.keys) + Array(browsers) where id == app || id.hasPrefix(app + ".") { return app }
        return id
    }

    /// The calling app — only one that is itself recording from the mic. A browser counts only with a Meet/Teams/
    /// WhatsApp-call style window open. Apps that are merely open (WhatsApp in the background) never count.
    nonisolated static func callApp(capturing: [String]) -> String? {
        if let id = capturing.first(where: { callApps[$0] != nil }) { return callApps[id] }
        guard capturing.contains(where: { browsers.contains($0) }) else { return nil }
        let titles = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowName as String] as? String }
        if titles.contains(where: { $0.hasPrefix("Meet - ") || $0.hasPrefix("Meet – ") || $0.contains("Google Meet") }) { return "Google Meet" }
        if titles.contains(where: { $0.contains("Microsoft Teams") && $0.lowercased().contains("call") }) { return "Teams" }
        if titles.contains(where: { $0.contains("Zoom") && $0.contains("Meeting") }) { return "Zoom" }
        return nil
    }

    // MARK: Screen recording (⇧⌘5 shows a stop button in the menu bar while recording)

    private var recordingPoll: Foundation.Timer?

    private func startRecordingWatch() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if id == "com.apple.screencaptureui" { self?.pollRecording(true) } }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if id == "com.apple.screencaptureui" { self?.pollRecording(false) } }
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.screencaptureui" }) { pollRecording(true) }
    }

    /// Only while the screenshot tool is running: check once a second for its menu-bar stop button.
    private func pollRecording(_ on: Bool) {
        recordingPoll?.invalidate(); recordingPoll = nil
        guard on else { hub?.setRecording(false); return }
        recordingPoll = Foundation.Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hub?.setRecording(Self.isRecording() || Self.inputBundleIDs().contains(Self.screenRecorder))
            }
        }
    }

    nonisolated static func isRecording() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            (w[kCGWindowOwnerName as String] as? String) == "screencaptureui"
                && (w[kCGWindowLayer as String] as? Int ?? 0) == Int(CGWindowLevelForKey(.statusWindow))
        }
    }

    // MARK: Focus (readable only with Full Disk Access; silently off otherwise)

    private var focusTimer: Foundation.Timer?
    private var lastFocus: String??

    nonisolated static var focusURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }
    nonisolated static var focusReadable: Bool { FileManager.default.isReadableFile(atPath: focusURL.path) }

    private func startFocus() {
        guard Self.focusReadable else { return }
        lastFocus = .some(Self.currentFocus())
        focusTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocus() }
        }
    }

    private func checkFocus() {
        let now = Self.currentFocus()
        guard case .some(let before) = lastFocus, before != now else { return }
        lastFocus = .some(now)
        if let now { hub?.show(.init(kind: .focus(name: now, on: true), duration: 2.5)) }
        else if let before { hub?.show(.init(kind: .focus(name: before, on: false), duration: 2.5)) }
    }

    /// The active Focus mode's name (e.g. "Do Not Disturb", "Work"), or nil.
    nonisolated static func currentFocus() -> String? {
        guard let data = try? Data(contentsOf: focusURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let store = (json["data"] as? [[String: Any]])?.first,
              let records = store["storeAssertionRecords"] as? [[String: Any]], let first = records.first else { return nil }
        let mode = (first["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String ?? ""
        if mode.contains("sleep") { return "Sleep" }
        if mode.contains("work") { return "Work" }
        if mode.contains("personal") { return "Personal" }
        if mode.contains("driving") { return "Driving" }
        if mode.contains("reduce-interruptions") { return "Reduce Interruptions" }
        return "Do Not Disturb"
    }
}
