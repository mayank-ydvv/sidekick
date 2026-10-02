import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use the app as host; don't start hotkeys, downloads or windows.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if let files = UserDefaults.standard.string(forKey: "sttProbe") {
            Task { await STTProbe.run(env: env, files: files.split(separator: ",").map(String.init)) }
            return
        }
        if UserDefaults.standard.bool(forKey: "memoryProbe") {
            Task { await MemoryProbe.run(env: env) }
            return
        }
        if UserDefaults.standard.bool(forKey: "requestCalendar") {
            // Hidden: ask for Calendar + Reminders access now (the system shows its own Allow dialogs).
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                print("CAL before: calendar=\(AppleTools.accessDescription(.event)) reminders=\(AppleTools.accessDescription(.reminder))")
                _ = await AppleTools.requestAccess(.event)
                _ = await AppleTools.requestAccess(.reminder)
                print("CAL after: calendar=\(AppleTools.accessDescription(.event)) reminders=\(AppleTools.accessDescription(.reminder))")
                fflush(stdout)
                exit(0)
            }
            return
        }
        if let q = UserDefaults.standard.string(forKey: "searchProbe") {
            Task { await SearchProbe.run(env: env, query: q) }
            return
        }
        if UserDefaults.standard.bool(forKey: "ocrProbe") {
            Task { await OCRProbe.run(env: env) }
            return
        }
        if let t = UserDefaults.standard.string(forKey: "typeProbe") {
            TypeProbe.text = String(decoding: Array(t.utf8), as: UTF8.self)
            Task { await TypeProbe.run() }
            return
        }
        if let q = UserDefaults.standard.string(forKey: "talkProbe") {
            // Handed over via a static (passing the string into the async call crashed in optimized builds).
            TalkProbe.question = String(decoding: Array(q.utf8), as: UTF8.self)
            Task { await TalkProbe.run(env: env) }
            return
        }
        if let prefix = UserDefaults.standard.string(forKey: "voiceProbe") {
            Task { await VoiceProbe.run(prefix: prefix) }
            return
        }
        if UserDefaults.standard.bool(forKey: "langProbe") {
            Task { await LangProbe.run(env: env) }
            return
        }
        if UserDefaults.standard.bool(forKey: "uiTest") {
            Task { await UITest.run(env: env) }
            return
        }
        if UserDefaults.standard.bool(forKey: "geminiProbe") {
            Task { await GeminiProbe.run(env: env) }
            return
        }
        if UserDefaults.standard.bool(forKey: "featureTest") {
            Task { await FeatureTest.run(env: env) }
            return
        }
        if UserDefaults.standard.bool(forKey: "selfTest") {
            Task { await SelfTest.run(env: env) }
            return
        }
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "benchWhisper") {
            Task { await WhisperBench.run(path: path, model: env.settings.data.whisperModel, stt: env.stt) }
            return
        }
        #endif
        env.launch()
        // Hidden (visual checks): with `-pointDemo YES`, posting the distributed notification
        // "com.mayankyadav.sidekick.pointDemo" makes the buddy point at the Apple menu.
        if UserDefaults.standard.bool(forKey: "pointDemo") {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.mayankyadav.sidekick.pointDemo"),
                                                                object: nil, queue: .main) { [env] _ in
                MainActor.assumeIsolated { env.coordinator.overlay.demo() }
            }
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.mayankyadav.sidekick.message"),
                                                                object: nil, queue: .main) { [env] n in
                let text = n.object as? String ?? "didn't catch that"
                MainActor.assumeIsolated { env.coordinator.debugMessage(text) }
            }
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.mayankyadav.sidekick.heading"),
                                                                object: nil, queue: .main) { [env] n in
                let deg = Double(n.object as? String ?? "0") ?? 0
                MainActor.assumeIsolated { env.coordinator.overlay.debugHeading(deg * .pi / 180) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.coordinator.cancelAll()
        env.hotkeys.stop()
    }
}
