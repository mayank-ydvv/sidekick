import AppKit

/// Runs one voice question end-to-end (spec §4 data flow) and owns cancellation.
@MainActor
final class TalkCoordinator {
    private let state: AppState
    private let settings: AppSettings
    private let usage: UsageStore
    private let audio: AudioCapture
    /// Screen-aware writing: called with the text of a [TYPE] tag.
    var onType: ((String) -> Void)?
    /// Memory files for the prompt (profile, volatile, active skills).
    var memoryContext: (String) -> (profile: String, volatile: String, skills: String) = { _ in ("", "", "") }
    /// Names from memory and words from the personal dictionary, to help Whisper spell them.
    var listeningHints: () -> (memory: [String], dictionary: [String]) = { ([], []) }
    /// Called after each finished voice exchange (text only).
    var onTurnFinished: ((ConversationTurn, String, TokenUsage?, Double) -> Void)?
    /// [AGENT task="…"] → hand off (task, recent conversation as text).
    var onAgent: ((String, String) -> Void)?
    /// Lets a waiting agent consume a spoken reply ("yes", an answer…). Returns true if consumed.
    var agentInterceptor: ((String) -> Bool)?
    /// True while dictation owns the mic.
    var micBusyElsewhere: () -> Bool = { false }
    private let stt: WhisperKitSTT
    private let capturer: ScreenCapturer
    private let gemini: GeminiClient
    let tts: SpeechOutput
    private let bubble: CursorBubble
    let overlay: OverlayController

    private var captureTask: Task<ScreenContext?, Never>?
    private var pipeline: Task<Void, Never>?
    private var history: [ConversationTurn] = []
    private var template = PromptBuilder.loadTemplate()
    private var hideWork: DispatchWorkItem?
    private var streaming = false
    private var pressActive = false
    private var smartUnavailable = false
    /// When the fast model is rate-limited / slow, talk uses the cheap model until this time.
    private var fastBlockedReason = ""
    static let talkFirstTokenTimeout: TimeInterval = 6
    static let cheapFirstTokenTimeout: TimeInterval = 12

    /// UI tests: stop after transcription (no Gemini call); the transcript lands in `state.reply`.
    var dryRun = false
    private(set) var lastInkStrokeCount = 0
    /// Test hook: every tag the model emits.
    var onTag: ((OverlayTag) -> Void)?
    /// Called after a spoken settings change is applied (reload models, move the buddy…).
    var onSettingApplied: ((SettingsMap.Change) -> Void)?
    /// A settings change waiting for the user's spoken "yes".
    private var pendingSetting: SettingsMap.Change?
    /// Quiet mode (call / screen share / Focus): no voice, no unprompted bubbles.
    var isQuiet: () -> Bool = { false }

    // Teaching + spatial context
    private var teaching = TeachingSession()
    private let clicks = ClickObserver()
    private let skills = AppSkillsLoader()
    private var inkStrokes: [[CGPoint]] = []

    // Timing marks (systemUptime seconds)
    private var tArmed: TimeInterval = 0
    private var tReleased: TimeInterval = 0

    init(state: AppState, settings: AppSettings, usage: UsageStore, audio: AudioCapture, stt: WhisperKitSTT, capturer: ScreenCapturer, gemini: GeminiClient) {
        self.audio = audio
        self.state = state
        self.settings = settings
        self.usage = usage
        self.stt = stt
        self.capturer = capturer
        self.gemini = gemini
        self.tts = SpeechOutput()
        self.bubble = CursorBubble(state: state)
        bubble.enabled = { [weak settings] in settings?.data.showCursorBubble ?? false }
        self.overlay = OverlayController(state: state, settings: settings)
        overlay.onBuddyMoved = { [weak self] p, d in
            guard let self, self.state.bubbleVisible else { return }
            self.bubble.place(anchor: p, duration: d)
        }

        audio.onLevel = { [weak state] lvl in state?.level = lvl }
        tts.onFirstAudio = { [weak self] in self?.markFirstAudio() }
        tts.onFinished = { [weak self] in self?.speechFinished() }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func prewarm() {
        applyVoiceSettings()
        tts.prewarm()
    }

    // MARK: Hotkey

    func handle(_ e: HotkeyEvent) {
        if e == .armed {
            guard !micBusyElsewhere() else { return }
            pressActive = true
        } else {
            guard pressActive else { return }
            if e != .began { pressActive = false }
        }
        switch e {
        case .armed: armed()
        case .began: began()
        case .ended: ended()
        case .cancelled, .tap: cancelledPress()
        }
    }

    /// Esc: returns true if we consumed it.
    func escape() -> Bool {
        guard state.isBusy || tts.isSpeaking || audio.isRunning || teaching.isActive else { return false }
        endLesson()
        cancelAll()
        hideBubble(after: 0)
        return true
    }

    private func armed() {
        tArmed = now
        // Barge-in: stop anything in flight before listening again.
        if pipeline != nil || tts.isSpeaking { cancelAll() }
        overlay.clearAnnotations()
        audio.onLevel = { [weak state] lvl in state?.level = lvl }
        do {
            try audio.start()
        } catch {
            Log.audio.error("audio start failed: \(error.localizedDescription, privacy: .public)")
        }
        // Warm the TLS connection while the user is still talking.
        let gemini = gemini
        Task.detached(priority: .userInitiated) { await gemini.preconnect() }
        let readURL = settings.data.readBrowserURL
        let capturer = capturer
        captureTask = Task.detached(priority: .userInitiated) {
            do {
                // Read names off the screen while the user is still speaking (helps Whisper spell them).
                var shot = try await capturer.capture(readBrowserURL: readURL)
                shot.vocabulary = Vocabulary.fromScreen(shot.image)
                return shot
            }
            catch {
                Log.screen.error("capture failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private func began() {
        hideWork?.cancel()
        state.modelNote = nil
        clicks.stop()   // pause a lesson's click-wait while the user talks
        state.timings = [:]
        state.transcript = ""
        state.reply = ""
        state.phase = .listening
        tts.warmNatural()
        overlay.beginInkCapture()
        bubble.show(near: overlay.buddyPoint)
        let ms = Int((now - tArmed - 0.15) * 1000)  // UI latency beyond the hold threshold
        state.timings["hotkey→listening"] = max(0, ms)
    }

    private func cancelledPress() {
        audio.stop()
        captureTask?.cancel()
        captureTask = nil
        _ = overlay.endInkCapture()
    }

    private func ended() {
        tReleased = now
        let samples = audio.stop()
        inkStrokes = overlay.endInkCapture()
        lastInkStrokeCount = inkStrokes.count
        let capture = captureTask
        captureTask = nil
        pipeline = Task { [weak self] in
            await self?.run(samples: samples, capture: capture)
        }
    }

    var isSpeaking: Bool { tts.isSpeaking }

    /// Feature test: a typed question through the exact voice pipeline (screenshot + prompt + stream + tags).
    func askText(_ text: String) async {
        tReleased = now
        state.timings = [:]
        state.transcript = text
        state.reply = ""
        bubble.show(near: overlay.buddyPoint)
        let shot = try? await capturer.capture(readBrowserURL: settings.data.readBrowserURL)
        await ask(userText: text, shot: shot, inked: false)
    }

    var lessonActive: Bool { teaching.isActive }
    var lessonWaitingForClick: Bool { teaching.phase == .waitingForClick }
    var lessonTarget: TeachTarget? { teaching.target }

    /// Always-on mode: one utterance cut by silence. Looks at the screen now, then runs the normal pipeline.
    func handleUtterance(_ samples: [Float]) {
        guard pipeline == nil, !pressActive else { return }
        tts.warmNatural()
        tReleased = now
        state.timings = [:]
        state.transcript = ""
        state.reply = ""
        hideWork?.cancel()
        bubble.show(near: overlay.buddyPoint)
        let readURL = settings.data.readBrowserURL
        let capturer = capturer
        let capture = Task.detached(priority: .userInitiated) { try? await capturer.capture(readBrowserURL: readURL) }
        pipeline = Task { [weak self] in await self?.run(samples: samples, capture: capture) }
    }

    func cancelAll() {
        pipeline?.cancel()
        pipeline = nil
        streaming = false
        captureTask?.cancel()
        captureTask = nil
        audio.stop()
        tts.stop()
        state.phase = .idle
        state.level = 0
    }

    // MARK: Voice pipeline

    /// Whisper drops very short clips (a one-word "yes" is under a second): pad them with silence to 1.5 s, and if a
    /// short clip still comes back empty, retry it as English (language detection is unreliable on tiny clips).
    private func transcribeUtterance(_ trimmed: [Float], prompt: String? = nil) async throws -> String {
        let lang = settings.data.language.isEmpty ? nil : settings.data.language
        let rate = Int(AudioCapture.sampleRate)
        let short = trimmed.count < rate * 3 / 2
        let audio = short ? Self.padShort(trimmed, to: 1.5) : trimmed
        // Vocabulary hints help names in real sentences; one-word answers ("yes") are safer without them.
        let hint = short ? nil : prompt
        var raw = try await stt.transcribe(audio, language: lang, prompt: hint)
        // Whisper occasionally just repeats the hint list instead of transcribing: retry without it.
        if let hint, Self.echoesPrompt(raw, hint) { raw = try await stt.transcribe(audio, language: lang, prompt: nil) }
        if short, lang == nil, Self.cleanTranscript(raw).count < 2 {
            return try await stt.transcribe(audio, language: "en", prompt: nil)
        }
        return raw
    }

    /// The Whisper hint list for this turn: names on screen (read while the user spoke) + memory + dictionary.
    /// Waits at most 0.3 s for the screenshot so short questions don't get slower.
    private func listeningPrompt(_ capture: Task<ScreenContext?, Never>?) async -> String? {
        var screen: [String] = []
        if let capture {
            let shot = await withTaskGroup(of: ScreenContext??.self) { g in
                g.addTask { await capture.value }
                g.addTask { try? await Task.sleep(nanoseconds: 300_000_000); return .some(nil) }
                let first = await g.next() ?? nil
                g.cancelAll()
                return first ?? nil
            }
            screen = shot?.vocabulary ?? []
        }
        let hints = listeningHints()
        let p = Vocabulary.prompt(screen: screen, memory: hints.memory, dictionary: hints.dictionary)
        if let p { state.timings["listening hints"] = p.split(separator: ",").count }
        return p
    }

    nonisolated static func echoesPrompt(_ transcript: String, _ prompt: String) -> Bool {
        let t = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !t.isEmpty else { return false }
        let hints = prompt.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) }
        let words = t.split(separator: " ").count
        let matched = hints.filter { t.contains($0) }.count
        return matched >= 3 && matched * 2 >= max(1, words / 2)
    }

    nonisolated static func padShort(_ s: [Float], to seconds: Double) -> [Float] {
        let target = Int(AudioCapture.sampleRate * seconds)
        guard s.count < target else { return s }
        let lead = min(Int(AudioCapture.sampleRate * 0.3), target - s.count)
        return [Float](repeating: 0, count: lead) + s + [Float](repeating: 0, count: target - s.count - lead)
    }

    /// Probe only: the exact front half of a voice turn, returning what would happen to the audio.
    func transcribeForProbe(_ samples: [Float]) async -> String {
        let trimmed = VAD.trimSilence(samples)
        let secs = String(format: "%.2fs", Double(trimmed.count) / AudioCapture.sampleRate)
        guard trimmed.count >= Int(AudioCapture.sampleRate * 0.25) else { return "trimmed to \(secs) → DIDN'T CATCH (too short)" }
        let hint = UserDefaults.standard.string(forKey: "sttHint")
        let raw = (try? await transcribeUtterance(trimmed, prompt: hint)) ?? "(error)"
        let text = Self.cleanTranscript(raw)
        return "trimmed to \(secs) · whisper=\"\(raw)\" · cleaned=\"\(text)\"" + (text.count >= 2 ? "" : " → DIDN'T CATCH")
    }

    private func run(samples: [Float], capture: Task<ScreenContext?, Never>?) async {
        state.level = 0
        state.phase = .transcribing
        let trimmed = VAD.trimSilence(samples)
        guard trimmed.count >= Int(AudioCapture.sampleRate * 0.25) else {
            if dryRun { state.reply = "dry run: (silence)" }
            return resumeLessonOr { didntCatch() }
        }
        guard await stt.isReady else {
            return show(message: "still warming up my ears… try again in a sec")
        }

        let sttStart = now
        let text: String
        do {
            text = Self.cleanTranscript(try await transcribeUtterance(trimmed, prompt: await listeningPrompt(capture)))
        } catch {
            return show(message: Friendly.message(error))
        }
        if Task.isCancelled { return }
        state.timings["whisper"] = Int((now - sttStart) * 1000)
        state.timings["audio length"] = trimmed.count * 1000 / Int(AudioCapture.sampleRate)
        guard text.count >= 2 else { return resumeLessonOr { didntCatch() } }
        state.transcript = text
        if dryRun {
            state.reply = "dry run: " + text
            finishTurn()
            return
        }

        // A pending settings change: "yes" applies it, "no" drops it.
        if let change = pendingSetting {
            pendingSetting = nil
            if SettingsMap.isYes(text) {
                SettingsMap.apply(change, to: &settings.data)
                onSettingApplied?(change)
                state.reply = "done — \(change.description)."
                speak("done.")
                finishTurn()
                return
            } else if SettingsMap.isNo(text) {
                state.reply = "okay, leaving it as is."
                speak("okay.")
                finishTurn()
                return
            }
        }

        // An agent waiting for approval or an answer gets the reply directly.
        if let intercept = agentInterceptor, intercept(text) {
            state.reply = "got it."
            finishTurn()
            return
        }

        // Lesson control words ("skip", "go back", "stop") never need the model to interpret them.
        if teaching.isActive, let cmd = TeachingSession.command(from: text) {
            switch cmd {
            case .stop:
                endLesson()
                overlay.clearAnnotations()
                state.reply = "okay, we'll stop here."
                speak("okay, we'll stop here.")
                finishTurn()
                return
            case .skip:
                return await continueLesson(note: "Skip this step and go to the next one.")
            case .back:
                return await continueLesson(note: "Go back to the previous step.")
            }
        }

        state.phase = .thinking
        let waitShot = now
        var shot = await capture?.value
        if Task.isCancelled { return }
        state.timings["wait for screenshot"] = Int((now - waitShot) * 1000)
        let strokes = inkStrokes
        inkStrokes = []
        if !strokes.isEmpty, let s = shot {
            shot = await Task.detached(priority: .userInitiated) { ScreenCapturer.burnInk(strokes, into: s) }.value
        }
        await ask(userText: text, shot: shot, inked: !strokes.isEmpty)
    }

    /// Sends one turn to Gemini and plays it out: speech, drawings, lesson steps.
    private func ask(userText: String, shot: ScreenContext?, inked: Bool, tier forced: ModelTier? = nil, useCheap: Bool = false, forceFast: Bool = false, retried: Bool = false) async {
        usage.configure(prices: settings.data.prices, budget: settings.data.dailyBudgetUSD)
        if usage.meter.status() == .exceeded, settings.data.hardStopAtBudget {
            return show(message: "daily budget reached — raise it in settings to keep going")
        }
        state.phase = .thinking
        state.timings["release→request sent"] = Int((now - tReleased) * 1000)

        let mem = memoryContext(userText)
        var ctx = PromptBuilder.Context(profile: mem.profile, volatile: mem.volatile, activeSkills: mem.skills,
                                        appName: shot?.appName, windowTitle: shot?.windowTitle, url: shot?.url)
        ctx.appSkill = skills.skill(bundleID: shot?.bundleID, url: shot?.url) ?? ""
        ctx.activeSkills = [mem.skills, SettingsMap.promptBlock].filter { !$0.isEmpty }.joined(separator: "\n")
        var prompt = userText
        if inked { prompt += "\n(The user drew red ink on the screenshot to mark an area. Focus on the marked area.)" }
        if teaching.isActive, let step = teaching.stepLabel { prompt += "\n(We're in a step-by-step lesson, currently on \(step).)" }

        var tier = forced ?? ModelRouter.route(userText, mode: settings.data.modelTier)
        if tier == .smart, smartUnavailable { tier = .fast }
        let smart = tier == .smart
        let cheap = !forceFast && (useCheap || (!smart && ModelHealth.isBlocked(settings.data.fastModel)))
        let model = smart ? settings.data.smartModel : (cheap ? settings.data.cheapModel : settings.data.fastModel)
        var request = GeminiRequest(
            model: model,
            system: PromptBuilder.system(template: template, context: ctx) + PromptBuilder.languageLine(for: userText),
            turns: PromptBuilder.turns(history: history, userText: prompt, screenshot: shot?.jpeg),
            thinkingLevel: smart ? settings.data.smartThinkingLevel : settings.data.thinkingLevel,
            maxOutputTokens: smart ? 4096 : 1024
        )
        // Fast model: tight latency watchdog (then the cheap model). Cheap model: a looser one, then one fresh retry —
        // its latency varies a lot and a stuck request is usually fast the second time.
        if !smart { request.firstTokenTimeout = cheap ? Self.cheapFirstTokenTimeout : Self.talkFirstTokenTimeout }
        if cheap { request.thinkingLevel = "minimal" }   // "off" lets the model pick its own (slower) thinking
        state.modelNote = Self.modelNote(smart: smart, cheap: cheap, smartWanted: forced == .smart || ModelRouter.route(userText, mode: settings.data.modelTier) == .smart,
                                         smartUnavailable: smartUnavailable, reason: fastBlockedReason, until: ModelHealth.until(settings.data.fastModel))
        state.timings[smart ? "model: smart" : cheap ? "model: cheap" : "model: fast"] = 1

        applyVoiceSettings()
        tts.beginReply()
        teaching.replyStarted()
        var splitter = SentenceSplitter()
        var tags = TagParser()
        var full = ""
        var lastUsage: TokenUsage?
        var firstToken = true
        var firstSpeak = true
        var escalate = false
        var annotationTasks: [Task<Void, Never>] = []
        var tookAction = false
        streaming = true
        defer { streaming = false }
        do {
            stream: for try await chunk in gemini.stream(request) {
                if Task.isCancelled { return }
                if firstToken, !chunk.text.isEmpty {
                    firstToken = false
                    state.timings["release→first token"] = Int((now - tReleased) * 1000)
                }
                if let u = chunk.usage { lastUsage = u }
                for event in tags.push(chunk.text) {
                    switch event {
                    case .text(let t):
                        full += t
                        state.reply = full.trimmingCharacters(in: .whitespacesAndNewlines)
                        for s in splitter.push(t) {
                            if firstSpeak {
                                firstSpeak = false
                                state.timings["release→first chunk to tts"] = Int((now - tReleased) * 1000)
                            }
                            speak(s)
                        }
                    case .tag(.escalate) where !smart:
                        escalate = true
                        break stream
                    case .tag(let tag):
                        switch tag {
                        case .agent, .type, .setting: tookAction = true
                        default: break
                        }
                        if let t = handle(tag, screen: shot) { annotationTasks.append(t) }
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch let e as GeminiError where !smart && !cheap && full.isEmpty && Self.shouldFallBack(e) {
            // Fast model limited / overloaded / slow: answer with the cheap model, and keep using it for a while.
            ModelHealth.block(settings.data.fastModel, for: e)
            fastBlockedReason = Self.reason(e)
            state.timings["model: fast"] = nil
            Log.ai.notice("fast model fallback: \(e.localizedDescription, privacy: .public)")
            return await ask(userText: userText, shot: shot, inked: inked, tier: .fast, useCheap: true)
        } catch GeminiError.slow where cheap && full.isEmpty && !retried {
            Log.ai.notice("cheap model stalled; retrying once")
            state.timings["model: cheap"] = nil
            return await ask(userText: userText, shot: shot, inked: inked, tier: .fast, useCheap: true, retried: true)
        } catch let e as GeminiError where cheap && !useCheap && full.isEmpty && Self.shouldFallBack(e) {
            // The cheap model failed while we were avoiding the fast one: give the fast model one more try.
            Log.ai.notice("cheap model failed (\(e.localizedDescription, privacy: .public)); trying the fast model")
            state.timings["model: cheap"] = nil
            return await ask(userText: userText, shot: shot, inked: inked, tier: .fast, forceFast: true)
        } catch GeminiError.quotaUnavailable where smart && full.isEmpty {
            // The key's plan has no smart-model quota: answer with the fast model instead.
            smartUnavailable = true
            state.timings["model: smart"] = nil
            Log.ai.notice("smart model unavailable on this plan; falling back to fast")
            return await ask(userText: userText, shot: shot, inked: inked, tier: .fast)
        } catch {
            if Task.isCancelled { return }
            if let u = lastUsage { usage.record(model: model, usage: u) }
            return show(message: Friendly.message(error))
        }
        if Task.isCancelled { return }
        if !smart, !cheap { ModelHealth.succeeded(model) }
        var cost = 0.0
        if let u = lastUsage { cost = usage.record(model: model, usage: u) }

        if escalate, !smartUnavailable {
            // Flash asked for help: hand the same turn to the smart model.
            Log.ai.notice("escalating to smart model")
            tts.stop()
            state.reply = "let me think about that properly…"
            speak("let me think about that.")
            return await ask(userText: userText, shot: shot, inked: inked, tier: .smart)
        }

        if let rest = splitter.finish() { speak(rest) }
        if usage.meter.status() == .warning { Log.ai.info("daily budget at 80%") }

        // Safety nets for a forgotten [AGENT] tag: the reply promised to do something, or the user said yes to an
        // offer like "want me to open Spotify?".
        if !tookAction, ActionIntent.needsAgent(user: userText, reply: full) {
            Log.ai.notice("reply promised an action without [AGENT]; starting the task")
            _ = handle(.agent(task: userText), screen: shot)
        } else if !tookAction, let offer = history.last?.assistant,
                  ActionIntent.acceptedOffer(user: userText, previousReply: offer) {
            Log.ai.notice("user accepted an offer without [AGENT]; starting the task")
            let ask = history.last?.user ?? ""
            _ = handle(.agent(task: "Do what Sidekick offered: \"\(offer)\" (the user had asked: \"\(ask)\", and said \"\(userText)\")"), screen: shot)
        }

        let turn = ConversationTurn(user: userText, assistant: full)
        history.append(turn)
        if !full.isEmpty { onTurnFinished?(turn, model, lastUsage, cost) }
        if history.count > PromptBuilder.maxHistory { history.removeFirst(history.count - PromptBuilder.maxHistory) }

        // Let snapping finish so the lesson knows exactly where to expect the click.
        for t in annotationTasks { await t.value }
        if Task.isCancelled { return }
        if teaching.replyFinished() {
            clicks.start { [weak self] p in self?.userClicked(p) }
        }
        if pendingSetting == nil { state.stepLabel = teaching.stepLabel }

        if state.reply.isEmpty, annotationTasks.isEmpty { return show(message: "hmm, i got nothing back. try again?") }
        finishTurn()
        // `shot` (and its JPEG) goes out of scope here — never persisted.
    }

    nonisolated static func reason(_ e: GeminiError) -> String {
        switch e {
        case .rateLimited: "fast model hit its free-tier limit"
        case .quotaUnavailable: "fast model isn't on your plan"
        case .slow: "fast model was slow"
        default: "fast model is busy"
        }
    }

    /// Short line under the bubble explaining a non-default model (nil when everything is normal).
    nonisolated static func modelNote(smart: Bool, cheap: Bool, smartWanted: Bool, smartUnavailable: Bool,
                                      reason: String, until: Date, now: Date = Date()) -> String? {
        if cheap {
            let secs = Int(until.timeIntervalSince(now).rounded(.up))
            return "lite model · \(reason.isEmpty ? "fast model busy" : reason)" + (secs > 0 && secs < 600 ? " · back in ~\(secs)s" : "")
        }
        if smartWanted, !smart, smartUnavailable { return "fast model · smart model isn't on your plan" }
        if smart { return "smart model" }
        return nil
    }

    nonisolated static func shouldFallBack(_ e: GeminiError) -> Bool {
        switch e {
        case .rateLimited, .quotaUnavailable, .slow: true
        case .http(let code, _): code == 429 || code >= 500
        default: false
        }
    }

    /// How long to prefer the cheap model after a fast-model failure.
    nonisolated static func blockDuration(_ e: GeminiError) -> TimeInterval {
        switch e {
        case .rateLimited(_, let s): TimeInterval(max(30, s ?? 60))
        case .quotaUnavailable: 3600
        case .slow: 600
        default: 120
        }
    }

    /// Speaks + shows a short line (agent finished, etc.). Suppressed entirely in quiet mode (unprompted).
    func announce(_ text: String) {
        if settings.data.quietMode, isQuiet() { return }
        state.transcript = ""
        state.reply = text
        if !state.bubbleVisible { bubble.show(near: overlay.buddyPoint) }
        if settings.data.textOnly {
            state.phase = .idle
        } else {
            applyVoiceSettings()
            var splitter = SentenceSplitter()
            for s in splitter.push(text) { speak(s) }
            if let rest = splitter.finish() { speak(rest) }
        }
        hideBubble(after: 6)
    }

    // MARK: Tutorial

    /// Onboarding mini-task: the buddy circles the Apple menu and waits for the click.
    func tutorial() {
        endLesson()
        teaching = TeachingSession()
        teaching.onStep(n: 1, of: 2)
        let screen = NSScreen.screens[0]
        let target = CGPoint(x: screen.frame.minX + 20, y: screen.frame.maxY - NSStatusBar.system.thickness / 2)
        teaching.onTarget(TeachTarget(point: target, frame: CGRect(x: target.x - 14, y: target.y - 12, width: 28, height: 24), label: "the apple menu"))
        teaching.onWaitClick()
        _ = teaching.replyFinished()
        state.stepLabel = teaching.stepLabel
        overlay.demo()
        announce("let's try it. click the apple menu i'm circling.")
        tutorialActive = true
        clicks.start { [weak self] p in self?.userClicked(p) }
    }
    private var tutorialActive = false

    private func finishTurn() {
        if settings.data.textOnly || !tts.isSpeaking {
            state.phase = .idle
            hideBubble(after: 6)
        }
        pipeline = nil
    }

    /// Returns the annotation task (so the caller can await snapping) for drawing tags.
    private func handle(_ tag: OverlayTag, screen: ScreenContext?) -> Task<Void, Never>? {
        onTag?(tag)
        switch tag {
        case .point, .circle, .arrow, .highlight:
            guard let mapper = screen?.mapper else { return nil }
            if state.timings["release→first annotation"] == nil {
                state.timings["release→first annotation"] = Int((now - tReleased) * 1000)
            }
            let overlay = overlay
            return Task { [weak self] in
                if let target = await overlay.annotate(tag, mapper: mapper) {
                    self?.teaching.onTarget(target)
                }
            }
        case .step(let n, let of):
            teaching.onStep(n: n, of: of)
            state.stepLabel = teaching.stepLabel
        case .waitClick:
            teaching.onWaitClick()
        case .escalate:
            break   // already on the smart model
        case .type(let text):
            onType?(text)
        case .setting(let key, let value):
            if let change = SettingsMap.prepare(key: key, value: value, current: settings.data) {
                pendingSetting = change
                state.stepLabel = "say yes to \(change.description)"
            }
        case .agent(let task):
            let recent = history.suffix(4).map { "User: \($0.user)\nSidekick: \($0.assistant)" }.joined(separator: "\n")
            onAgent?(task, recent)
        }
        return nil
    }

    // MARK: Teaching

    private func userClicked(_ p: CGPoint) {
        let target = teaching.target
        switch teaching.click(at: p) {
        case .hit:
            clicks.stop()
            overlay.success(at: target?.point ?? p)
            if !settings.data.textOnly { tts.enqueue("nice!") }
            state.transcript = "✓ " + (teaching.stepLabel ?? "done")
            if tutorialActive {
                tutorialActive = false
                endLesson()
                announce("nice! now hold \(settings.data.pushToTalk.spoken), and ask me what's on your screen.")
                return
            }
            pipeline = Task { [weak self] in
                // Give the app a moment to react to the click before we look again.
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await self?.continueLesson(note: "I clicked it. What's the next step?")
            }
        case .miss(let hints):
            guard let target else { return }
            if hints <= 3 { overlay.repoint(target) }
            if hints == 1, !settings.data.textOnly { tts.enqueue("not quite, it's over here.") }
        case .ignored:
            break
        }
    }

    /// Takes a fresh look at the screen and asks for the next lesson step.
    private func continueLesson(note: String) async {
        tReleased = now
        state.phase = .thinking
        state.reply = ""
        hideWork?.cancel()
        if !state.bubbleVisible { bubble.show(near: overlay.buddyPoint) }
        overlay.clearAnnotations()
        let shot = try? await capturer.capture(readBrowserURL: settings.data.readBrowserURL)
        if Task.isCancelled { return }
        await ask(userText: note, shot: shot, inked: false)
    }

    private func endLesson() {
        teaching.end()
        clicks.stop()
        state.stepLabel = nil
    }

    /// Mid-lesson, an empty utterance shouldn't drop the click-wait.
    private func resumeLessonOr(_ fallback: () -> Void) {
        if teaching.phase == .waitingForClick {
            clicks.start { [weak self] p in self?.userClicked(p) }
            state.phase = .idle
            pipeline = nil
            hideBubble(after: 1)
        } else {
            fallback()
        }
    }

    /// Mutes speech for automated tests without touching the user's saved "text only" setting.
    var silenced = false

    /// Voice turns are always answered out loud (the user just spoke to us); typed chat never speaks.
    /// Quiet mode only holds back unprompted lines (see `announce`).
    private func speak(_ sentence: String) {
        guard !silenced, !settings.data.textOnly else { return }
        if state.phase != .speaking { state.phase = .speaking }
        tts.enqueue(MathText.clean(sentence).replacingOccurrences(of: "**", with: ""))
    }

    /// Settings → voice: say a short sample in the chosen voice.
    func previewVoice() {
        tts.stop()
        applyVoiceSettings()
        tts.beginReply()
        tts.enqueue("Hey! This is how I'll sound when we talk.")
        tts.enqueue("Pretty nice, right?")
    }

    private func applyVoiceSettings() {
        tts.apply(settings.data)
    }

    private func markFirstAudio() {
        guard tReleased > 0 else { return }
        let ms = Int((now - tReleased) * 1000)
        state.timings["release→first word"] = ms
        let summary = state.timings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        Log.perf.notice("timings \(summary, privacy: .public)")
    }

    private func speechFinished() {
        guard !streaming, state.phase == .speaking else { return }
        state.phase = .idle
        hideBubble(after: 4)
    }

    /// Visual checks only (`-pointDemo`): show a notch message.
    func debugMessage(_ text: String) { show(message: text) }

    private func didntCatch() { show(message: "didn't catch that") }

    private func show(message: String) {
        pipeline = nil
        state.phase = .message(message)
        if !state.bubbleVisible { bubble.show(near: overlay.buddyPoint) }
        hideBubble(after: 3)
    }

    private func hideBubble(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isBusy, !self.tts.isSpeaking else { return }
            self.bubble.hide()
            if case .message = self.state.phase { self.state.phase = .idle }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Whisper sometimes emits markers like "[BLANK_AUDIO]" or "(music)".
    nonisolated static func cleanTranscript(_ s: String) -> String {
        var out = SentenceSplitter.stripTags(s)
        // Whisper often mishears the app's own name ("side cake", "side kick").
        out = out.replacingOccurrences(of: #"(?i)\bside[\s-]?(cake|kick|kik|keck|kic)s?\b"#, with: "Sidekick", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\bhigh Sidekick\b"#, with: "Hi Sidekick", options: .regularExpression)
        while let open = out.firstIndex(of: "("), let close = out[open...].firstIndex(of: ")") {
            out.removeSubrange(open...close)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .isEmpty ? "" : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
