import AppKit
import ServiceManagement
import SwiftUI

/// Wires all services together. Created once at launch.
@MainActor
final class AppEnvironment {
    let state = AppState()
    let settings = AppSettings()
    let usage: UsageStore
    let stt = WhisperKitSTT()
    let capturer = ScreenCapturer()
    let gemini: GeminiClient
    let hotkeys: EventTapManager
    let windows = WindowManager()
    let audio = AudioCapture()
    let db: AppDatabase
    let dictionary: PersonalDictionary
    let memory = MemoryStore()
    let memoryUpdater: MemoryUpdater
    let chat: ChatStore
    private(set) var notch: NotchController!
    let agent: AgentRunner
    let alwaysOn = AlwaysOnListener()
    let buddies: BuddyStore
    let scheduler: RoutineScheduler
    let wiki = NotesWiki()
    let skills = SkillLibrary()
    let mcp = MCPManager()
    let quiet = QuietModeDetector()
    let suggester: ProactiveSuggester
    private var controlTaps = TapCounter()
    private(set) var agentCard: AgentCardController!
    private let chatTTS = SystemTTS()
    private(set) var coordinator: TalkCoordinator!
    private(set) var dictation: DictationController!

    init() {
        usage = UsageStore(prices: settings.data.prices, budget: settings.data.dailyBudgetUSD)
        gemini = GeminiClient(apiKey: { Keychain.get(Keychain.geminiAccount) })
        do {
            db = try AppDatabase.openDefault()
        } catch {
            Log.app.error("database open failed, using memory: \(error.localizedDescription, privacy: .public)")
            db = try! AppDatabase.inMemory()
        }
        usage.db = db
        dictionary = PersonalDictionary(db: db)
        memoryUpdater = MemoryUpdater(memory: memory, gemini: gemini, settings: settings, usage: usage)
        chat = ChatStore(db: db, gemini: gemini, settings: settings, usage: usage, memory: memory,
                         memoryUpdater: memoryUpdater, capturer: capturer)
        agent = AgentRunner(gemini: gemini, settings: settings, usage: usage, memory: memory, db: db)
        buddies = BuddyStore(db: db)
        suggester = ProactiveSuggester(settings: settings)
        scheduler = RoutineScheduler(store: buddies)
        hotkeys = EventTapManager(pushToTalk: settings.data.pushToTalk, dictate: settings.data.dictateKeys,
                                  alwaysOn: settings.data.alwaysOnKey)
        hotkeys.homeChord = settings.data.homeChord
        coordinator = TalkCoordinator(state: state, settings: settings, usage: usage, audio: audio,
                                      stt: stt, capturer: capturer, gemini: gemini)
        dictation = DictationController(state: state, settings: settings, audio: audio, stt: stt,
                                        gemini: gemini, usage: usage, dictionary: dictionary)
        coordinator.onType = { [weak self] text in self?.dictation.type(text) }
        coordinator.memoryContext = { [memory, skills] text in (memory.promptProfile, memory.promptVolatile, skills.promptText(for: text)) }
        chat.activeSkills = { [skills] text in skills.promptText(for: text) }
        configure(agent)
        suggester.makeRunner = { [unowned self] in
            let r = AgentRunner(gemini: self.gemini, settings: self.settings, usage: self.usage, memory: self.memory, db: self.db)
            self.configure(r)
            return r
        }
        coordinator.isQuiet = { [quiet] in quiet.isQuiet }
        quiet.ownMicActive = { [weak self] in
            guard let self else { return false }
            return self.audio.isRunning || self.alwaysOn.active
        }
        coordinator.onSettingApplied = { [weak self] change in
            guard let self else { return }
            if change.key == "speech_model" { self.loadWhisper(self.settings.data.whisperModel) }
            if change.key == "buddy" { self.coordinator.overlay.settingsChanged() }
        }
        chat.onBuddyTask = { [weak self] bid, text in
            guard let self, let b = self.buddies.buddy(bid) else { return }
            self.runBuddy(b, task: text)
        }
        scheduler.execute = { [weak self] routine, buddy in
            guard let self else { return (false, false) }
            return await self.runRoutine(routine, buddy: buddy)
        }
        coordinator.onTurnFinished = { [weak self] turn, model, u, cost in
            guard let self else { return }
            self.memoryUpdater.record(turn)
            self.chat.recordVoiceTurn(user: turn.user, assistant: turn.assistant, model: model, usage: u, cost: cost)
        }
        hotkeys.onHome = { [weak self] in self?.notch.toggle() }
        agentCard = AgentCardController(runner: agent) { [weak self] text in
            guard let self else { return }
            self.agent.start(task: text, context: "Previous task: \(self.agent.task)")
        }
        agent.onShow = { [weak self] in self?.agentCard.show() }
        observeAgentStatus()
        agent.onFinished = { [weak self] summary, files, buddy in
            guard let self else { return }
            self.coordinator.announce(summary)
            let fileList = files.map { "- `\($0.path)`" }.joined(separator: "\n")
            let text = summary + (fileList.isEmpty ? "" : "\n\n" + fileList)
            if let buddy {
                self.buddies.remember(buddy, summary)
                Task {
                    if let cid = await self.buddies.conversationId(for: buddy) {
                        self.chat.appendResult(conversationId: cid, user: nil, text: text, model: self.settings.data.smartModel)
                    }
                }
            } else {
                self.chat.recordVoiceTurn(user: "agent: \(self.agent.task)", assistant: text,
                                          model: self.settings.data.smartModel, usage: nil, cost: 0)
            }
        }
        coordinator.onAgent = { [weak self] task, context in
            guard let self else { return }
            if !self.agent.start(task: task, context: context) {
                self.coordinator.announce("i'm still finishing another task — ask me again in a moment.")
            }
        }
        hotkeys.onControl = { [weak self] e in
            guard let self, e == .tap else { return }
            if self.controlTaps.tap(at: ProcessInfo.processInfo.systemUptime) >= 3 {
                self.controlTaps.reset()
                self.alwaysOn.toggle()
            }
        }
        alwaysOn.isBusy = { [weak self] in
            guard let self else { return true }
            return self.state.isBusy || self.coordinator.isSpeaking || self.dictation.isBusy || self.audio.isRunning
        }
        alwaysOn.onUtterance = { [weak self] samples in self?.coordinator.handleUtterance(samples) }
        alwaysOn.onChange = { [weak self] on in
            guard let self else { return }
            self.state.alwaysOn = on
            if on, !UserDefaults.standard.bool(forKey: "alwaysOn.warned") {
                UserDefaults.standard.set(true, forKey: "alwaysOn.warned")
                self.coordinator.announce("always-on is on. headphones work best. triple-tap \(self.settings.data.alwaysOnKey.spoken) to stop.")
            } else {
                self.coordinator.announce(on ? "i'm listening." : "okay, stopped listening.")
            }
        }
        coordinator.agentInterceptor = { [weak self] text in self?.agent.handleVoice(text) ?? false }
        coordinator.micBusyElsewhere = { [weak self] in self?.dictation.isBusy ?? false }
        hotkeys.onPushToTalk = { [weak self] e in self?.coordinator.handle(e) }
        hotkeys.onDictate = { [weak self] e in
            guard let self else { return }
            // Don't fight over the mic with an active voice question.
            if self.dictation.mode == .idle, e == .armed, self.audio.isRunning { return }
            self.dictation.handle(e)
        }
        hotkeys.onEscape = { [weak self] in
            guard let self else { return false }
            if self.dictation.isBusy { self.dictation.cancel(); return true }
            if case .countdown = self.agent.status { self.agent.cancel(); return true }
            if self.agent.quietRuns, self.agent.status == .running, !self.state.isBusy { self.agent.cancel(); return true }
            if self.agent.isActive, ControlBanner.shared.isVisible { self.agent.cancel(); return true }
            return self.coordinator.escape()
        }
        state.hasAPIKey = Keychain.get(Keychain.geminiAccount) != nil
    }

    /// Quiet runs: the task card only pops up when the agent needs an answer or approval, or fails.
    private func observeAgentStatus() {
        withObservationTracking { _ = agent.status } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                if self.agent.quietRuns, !self.agent.headless {
                    switch self.agent.status {
                    case .asking, .needsApproval, .failed: self.agentCard.show()
                    // Answered / approved (or finished): get out of the way; the result is spoken.
                    case .running, .done, .cancelled: self.agentCard.dismiss()
                    default: break
                    }
                }
                self.observeAgentStatus()
            } }
        }
    }

    func launch() {
        installHotkeysIfNeeded()
        loadWhisper(settings.data.whisperModel)
        Task { await capturer.warm() }
        Task { await gemini.preconnect() }
        coordinator.prewarm()
        coordinator.overlay.start()
        applyHotkeys()
        audio.onDeviceChange = { [weak self] ok in
            guard let self, !ok else { return }
            self.coordinator.cancelAll()
            self.coordinator.announce("the microphone changed — hold \(self.settings.data.pushToTalk.symbols) again to talk.")
        }
        startNotch()
        scheduler.start()
        mcp.connectAll()
        quiet.start()
        suggester.start()
        applyLaunchAtLogin()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [capturer] _ in
            Task { await capturer.invalidate() }
        }
        if !settings.data.onboardingDone || !state.hasAPIKey || !PermissionsManager.requiredGranted {
            showOnboarding()
        }
    }

    func installHotkeysIfNeeded() {
        guard !hotkeys.isRunning else { return }
        state.hotkeyInstalled = hotkeys.start()
    }

    func loadWhisper(_ model: WhisperModel) {
        let state = state
        Task.detached(priority: .utility) { [stt] in
            await stt.load(model) { s in
                Task { @MainActor in state.whisper = s }
            }
        }
    }

    func saveAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Keychain.set(k, for: Keychain.geminiAccount)
        state.hasAPIKey = true
        Task { await gemini.preconnect() }
    }

    func removeAPIKey() {
        Keychain.delete(Keychain.geminiAccount)
        state.hasAPIKey = false
    }

    func showOnboarding() {
        windows.show(id: "onboarding", title: "welcome to sidekick", size: CGSize(width: 560, height: 640)) {
            OnboardingView(env: self)
        }
    }

    func finishOnboarding() {
        settings.data.onboardingDone = true
        windows.close(id: "onboarding")
        installHotkeysIfNeeded()
    }

    func showSettings() {
        windows.show(id: "settings", title: "sidekick settings", size: CGSize(width: 560, height: 460)) {
            SettingsView(env: self)
        }
    }

    // MARK: Agents & buddies

    private func configure(_ runner: AgentRunner) {
        runner.extraTools = { [unowned self] in
            BuddyTools.make(store: self.buddies, scheduler: self.scheduler, wiki: self.wiki) + self.mcp.agentTools
        }
        runner.buddyMemory = { [unowned self] b in self.buddies.memory(of: b) }
    }

    /// Runs a buddy in the foreground (with the agent card).
    func runBuddy(_ b: BuddyRecord, task: String) {
        if !agent.start(task: task, buddy: b) {
            Task {
                if let cid = await buddies.conversationId(for: b) {
                    chat.appendResult(conversationId: cid, user: nil,
                                      text: "i'm still working on another task (\(agent.task)) — send this again when it's done.", model: nil)
                }
            }
        }
    }

    /// Scheduled routine: a separate headless runner, result lands in the buddy's chat as unread.
    private func runRoutine(_ r: RoutineRecord, buddy: BuddyRecord) async -> (Bool, Bool) {
        // Quiet mode (Focus / call / screen share): try again later, not a failure.
        if settings.data.quietMode, quiet.isQuiet { return (false, true) }
        let runner = AgentRunner(gemini: gemini, settings: settings, usage: usage, memory: memory, db: db)
        configure(runner)
        let result: (String, Bool) = await withCheckedContinuation { cont in
            runner.onFinished = { summary, files, _ in
                let ok: Bool
                if case .done = runner.status { ok = true } else { ok = false }
                let list = files.map { "- `\($0.path)`" }.joined(separator: "\n")
                cont.resume(returning: (summary + (list.isEmpty ? "" : "\n\n" + list), ok))
            }
            runner.start(task: r.prompt, buddy: buddy, headless: true)
        }
        buddies.remember(buddy, "routine: " + result.0)
        if let cid = await buddies.conversationId(for: buddy) {
            chat.appendResult(conversationId: cid, user: "⏰ " + r.prompt, text: result.0, model: settings.data.smartModel)
        }
        let offline = result.0.contains("offline") || result.0.contains("internet")
        return (result.1, offline)
    }

    // MARK: Notch

    private func startNotch() {
        notch = NotchController { [unowned self] controller in AnyView(ChatView(ctx: self.chatContext(controller))) }
        notch.isStreaming = { [weak self] in self?.chat.isStreaming ?? false }
        notch.hoverEnabled = { [weak self] in self?.settings.data.peekOnHover ?? true }
        notch.onOpen = { [weak self] in self?.suggester.markOpened() }
        notch.start()
        notch.restorePopOutIfNeeded()
        observeUnread()
        observeActivity()
    }

    /// Mirrors what Sidekick is doing into the notch's live activity.
    private func observeActivity() {
        withObservationTracking {
            _ = state.phase; _ = state.dictation; _ = state.level; _ = state.dictationLevel; _ = agent.status
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.updateActivity()
                self?.observeActivity()
            } }
        }
        updateActivity()
    }

    private func updateActivity() {
        guard let notch else { return }
        let a: NotchUIState.Activity
        switch (state.dictation, state.phase) {
        case (.holding, _), (.handsFree, _): a = .dictating
        case (.processing, _): a = .thinking
        case (_, .listening): a = .listening
        case (_, .transcribing), (_, .thinking): a = .thinking
        case (_, .speaking): a = .speaking
        case (_, .message(let m)): a = .message(m.count > 110 ? String(m.prefix(108)) + "…" : m)   // two lines under the notch
        default:
            switch agent.status {
            case .running, .countdown: a = .working
            default: a = .none
            }
        }
        notch.ui.activityLevel = state.dictation == .idle ? state.level : state.dictationLevel
        notch.setActivity(a)
    }

    private func observeUnread() {
        withObservationTracking { _ = chat.unreadCount } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                self.notch.ui.unread = self.chat.unreadCount
                self.observeUnread()
            } }
        }
        notch.ui.unread = chat.unreadCount
    }

    func chatContext(_ controller: NotchController) -> ChatContext {
        ChatContext(
            store: chat, ui: controller.ui, controller: controller, settings: settings, memory: memory,
            buddies: buddies, wiki: wiki, suggester: suggester,
            runTask: { [weak self] task in self?.agent.start(task: task) },
            readAloud: { [weak self] text in
                guard let self else { return }
                self.chatTTS.stop()
                self.chatTTS.voiceIdentifier = self.settings.data.ttsVoiceID
                self.chatTTS.rate = self.settings.data.ttsRate
                var splitter = SentenceSplitter()
                for s in splitter.push(text) { self.chatTTS.enqueue(s) }
                if let rest = splitter.finish() { self.chatTTS.enqueue(rest) }
            },
            openSettings: { [weak self] in self?.showSettings() },
            micStart: { [weak self] in
                guard let self, !self.audio.isRunning else { return }
                try? self.audio.start()
            },
            micStop: { [weak self] in
                guard let self else { return nil }
                let samples = VAD.trimSilence(self.audio.stop())
                guard samples.count > 4000 else { return nil }
                let lang = self.settings.data.language.isEmpty ? nil : self.settings.data.language
                let raw = try? await self.stt.transcribe(samples, language: lang, prompt: self.dictionary.promptWords)
                return raw.map(TalkCoordinator.cleanTranscript)
            },
            micLevel: { [weak self] in self?.state.level ?? 0 }
        )
    }

    /// Settings → privacy: wipes the database, memory, dictionary and the API key.
    func deleteAllData() {
        Task {
            try? await db.wipe()
            memory.deleteAll()
            dictionary.removeAll()
            removeAPIKey()
            chat.newChat()
            for s in mcp.servers { mcp.remove(s) }
            try? FileManager.default.removeItem(at: wiki.directory)
            try? FileManager.default.removeItem(at: skills.directory)
            try? FileManager.default.removeItem(at: BuddyStore.root)
            UserDefaults.standard.removeObject(forKey: "buddies.defaults")
            UserDefaults.standard.removeObject(forKey: "skills.installed")
        }
    }

    /// Applies hotkey settings live (no relaunch).
    func applyHotkeys() {
        let d = settings.data
        hotkeys.updateBinding(.talk, d.pushToTalk)
        hotkeys.updateBinding(.dictate, d.dictateKeys)
        hotkeys.updateBinding(.control, d.alwaysOnKey)
        hotkeys.homeChord = d.homeChord
        coordinator.overlay.inkModifiers = d.pushToTalk
        UserDefaults.standard.set(d.pushToTalk.symbols, forKey: "talkSymbols")
    }

    /// ⌃⌥ is VoiceOver's modifier; warn when both are in use.
    var hotkeyConflict: String? {
        guard NSWorkspace.shared.isVoiceOverEnabled, settings.data.pushToTalk == [.control, .option] else { return nil }
        return "⌃⌥ clashes with VoiceOver — change push to talk in settings → shortcuts"
    }

    func applyLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if settings.data.launchAtLogin, svc.status != .enabled { try svc.register() }
            if !settings.data.launchAtLogin, svc.status == .enabled { try svc.unregister() }
        } catch {
            Log.app.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startTutorial() {
        windows.close(id: "onboarding")
        settings.data.onboardingDone = true
        coordinator.tutorial()
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
