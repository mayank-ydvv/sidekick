import AppKit
import AVFoundation
import GRDB

/// `Sidekick -featureTest YES`: drives every feature through the real code paths with the saved key.
/// Voice is muted (text-only) during the run; test chats, files, buddies and memory edits are cleaned up.
@MainActor
enum FeatureTest {
    static var lines: [String] = []
    static func log(_ s: String) { lines.append(s); print("FT " + s); fflush(stdout) }
    static func pass(_ name: String, _ detail: String = "") { log("PASS  \(name)\(detail.isEmpty ? "" : " — " + detail)") }
    static func fail(_ name: String, _ detail: String) { log("FAIL  \(name) — \(detail)") }
    static func info(_ name: String, _ detail: String) { log("INFO  \(name) — \(detail)") }

    static func run(env: AppEnvironment) async {
        let savedTextOnly = env.settings.data.textOnly
        env.settings.data.textOnly = true
        env.coordinator.silenced = true
        let memBackup = (env.memory.profile, env.memory.volatile)
        env.launch()
        let savedTurnHook = env.coordinator.onTurnFinished
        env.coordinator.onTurnFinished = nil   // test turns must not train memory or fill chat history
        while true {   // wait for whisper
            if case .ready = env.state.whisper { break }
            if case .failed = env.state.whisper { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // 1) Permissions + hotkeys
        for p in Permission.allCases { info("permission \(p.title)", PermissionsManager.isGranted(p) ? "granted" : "NOT granted") }
        env.state.hotkeyInstalled ? pass("event tap (hotkeys)") : fail("event tap (hotkeys)", "not installed — accessibility missing?")

        // 2) Models
        let key = Keychain.get(Keychain.geminiAccount) ?? ""
        for (label, m) in [("fast", env.settings.data.fastModel), ("smart", env.settings.data.smartModel), ("cheap", env.settings.data.cheapModel)] {
            do { try await env.gemini.validate(key: key, model: m); pass("model \(label) \(m) exists") }
            catch { fail("model \(label) \(m)", Friendly.message(error)) }
        }

        // 3) Voice pipeline (typed in, same path) — tags, latency
        var tags: [OverlayTag] = []
        env.coordinator.onTag = { tags.append($0) }
        func turn(_ q: String) async -> (String, [OverlayTag], [String: Int], Double) {
            tags = []
            let t0 = ProcessInfo.processInfo.systemUptime
            await env.coordinator.askText(q)
            return (env.state.reply, tags, env.state.timings, ProcessInfo.processInfo.systemUptime - t0)
        }
        func ms(_ t: [String: Int]) -> String { ["release→request sent", "release→first token", "release→first chunk to tts"].compactMap { k in t[k].map { "\(k.replacingOccurrences(of: "release→", with: ""))=\($0)ms" } }.joined(separator: " ") }

        var (r, tg, tm, dur) = await turn("What's on my screen right now? One sentence.")
        if case .message(let m) = env.state.phase { fail("talk: describe screen", m) }
        else if r.isEmpty { fail("talk: describe screen", "empty reply") }
        else { pass("talk: describe screen", "\"\(r.prefix(120))\" · \(ms(tm)) · total \(Int(dur * 1000))ms") }

        for i in 1...2 {
            let (r2, _, tm2, d2) = await turn("Quick: what app is in front? 5 words max.")
            info("latency sample \(i)", "\(ms(tm2)) · total \(Int(d2 * 1000))ms · \"\(r2.prefix(60))\"")
        }
        (r, tg, tm, dur) = await turn("Where is the Apple menu? Point at it.")
        if let p = tg.first(where: { if case .point = $0 { return true }; if case .circle = $0 { return true }; return false }) {
            pass("pointing tag", "\(p)")
        } else { fail("pointing tag", "no POINT/CIRCLE in reply: \"\(r.prefix(100))\" tags=\(tg)") }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        // AX snapping at the Apple menu (does our own overlay block hit-testing?)
        let scr = NSScreen.screens[0]
        let apple = CGPoint(x: scr.frame.minX + 20, y: scr.frame.maxY - NSStatusBar.system.thickness / 2)
        let el = await Task.detached { AXInspector.snap(apple, primaryHeight: scr.frame.height) }.value
        if let el { pass("AX snap (Apple menu)", "\(el.role) \"\(el.title ?? "")\" \(el.frame)") }
        else { fail("AX snap (Apple menu)", "no actionable element found within 40pt") }

        (r, tg, tm, dur) = await turn("Teach me how to create a new folder in Finder.")
        let hasStep = tg.contains { if case .step = $0 { return true }; return false }
        let hasWait = tg.contains { $0 == .waitClick }
        if hasStep && hasWait {
            pass("teaching tags", "STEP+WAIT_CLICK · waiting=\(env.coordinator.lessonWaitingForClick) target=\(env.coordinator.lessonTarget.map { "\($0.point)" } ?? "nil")")
        } else { fail("teaching tags", "step=\(hasStep) wait=\(hasWait) reply=\"\(r.prefix(100))\"") }
        _ = env.coordinator.escape()

        (r, tg, tm, dur) = await turn("Please talk slower from now on.")
        tg.contains { if case .setting = $0 { return true }; return false }
            ? pass("settings tag", "\(tg)") : fail("settings tag", "no SETTING tag; reply=\"\(r.prefix(100))\"")
        _ = env.coordinator.escape()

        (r, tg, tm, dur) = await turn("Write a short reply in the text box saying I'll be 10 minutes late.")
        tg.contains { if case .type = $0 { return true }; return false }
            ? info("type tag", "emitted (insertion skipped in test)") : fail("type tag", "no TYPE tag; reply=\"\(r.prefix(100))\"")

        (r, tg, tm, dur) = await turn("Make a CSV of the 3 biggest Indian IT companies by revenue and save it.")
        tg.contains { if case .agent = $0 { return true }; return false }
            ? pass("agent tag", "\(tg.first { if case .agent = $0 { return true }; return false }!)") : fail("agent tag", "no AGENT tag; reply=\"\(r.prefix(100))\"")
        env.agent.cancel()   // the tag starts a countdown; the agent itself is tested headless below
        env.agentCard.hide()

        env.settings.data.modelTier = .auto
        (r, tg, tm, dur) = await turn("Think hard: in one sentence, why is the sky blue?")
        if r.isEmpty { fail("router → smart", "no reply (\(env.state.phase))") }
        else { pass("router (\(tm["model: smart"] != nil ? "smart" : "fell back to fast"))", "\"\(r.prefix(100))\" · \(ms(tm)) · \(Int(dur * 1000))ms") }

        // 4) TTS voice (synthesize to buffer, no sound)
        let clip = await SelfTest.synthesize("Testing one two three.")
        (clip?.count ?? 0) > 8000 ? pass("tts synthesis") : fail("tts synthesis", "no audio produced")

        // 5) Dictation pipeline (no insertion): speech → whisper → cleaner → dictionary
        if let c = await SelfTest.synthesize("um hello comma this is a dictation test period") {
            let raw = (try? await env.stt.transcribe(VAD.trimSilence(c), language: nil, prompt: env.dictionary.promptWords)) ?? ""
            let cleaned = env.dictionary.apply(TextCleaner.clean(TalkCoordinator.cleanTranscript(raw)))
            cleaned.lowercased().contains("dictation test") ? pass("dictation pipeline", "\"\(raw)\" → \"\(cleaned)\"") : fail("dictation pipeline", "\"\(raw)\" → \"\(cleaned)\"")
        }

        // 6) Chat: send, stream, save, title, FTS
        env.chat.newChat()
        env.chat.send("Give me a tiny markdown example: a heading, 2 bullets, and a 2-line Swift code block.")
        let chatStart = Date()
        while env.chat.isStreaming || env.chat.messages.count < 2, Date().timeIntervalSince(chatStart) < 60 { try? await Task.sleep(nanoseconds: 200_000_000) }
        if let e = env.chat.errorText { fail("chat send", e) }
        else if let a = env.chat.messages.last, a.role == "assistant" {
            let blocks = Markdown.parse(a.text)
            let hasCode = blocks.contains { if case .code = $0 { return true }; return false }
            pass("chat send + markdown", "\(blocks.count) blocks, code block=\(hasCode), \(Int(Date().timeIntervalSince(chatStart) * 1000))ms")
        } else { fail("chat send", "no assistant message (\(env.chat.messages.count) msgs)") }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let title = env.chat.selected?.title ?? "?"
        title != "new chat" ? pass("chat title generation", "\"\(title)\"") : fail("chat title generation", "still \"new chat\"")
        let hits = (try? await env.db.searchConversationIds("swift")) ?? []
        hits.contains(env.chat.selectedId ?? -1) ? pass("chat FTS search") : fail("chat FTS search", "conversation not found for 'swift'")
        if let c = env.chat.selected { env.chat.delete(c) }

        // 7) Memory updater
        let mu = MemoryUpdater(memory: env.memory, gemini: env.gemini, settings: env.settings, usage: env.usage)
        mu.record(ConversationTurn(user: "My name is Mayank and please keep answers short.", assistant: "Got it, Mayank."))
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        env.memory.profile.lowercased().contains("mayank") ? pass("memory updater", env.memory.profile.replacingOccurrences(of: "\n", with: " | "))
            : fail("memory updater", "profile not updated: \"\(env.memory.profile)\"")
        env.memory.setProfile(memBackup.0); env.memory.setVolatile(memBackup.1)

        // 8) Agent (headless): CSV task
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: BuddyStore.folder(for: "General Helper").path)) ?? [])
        let (agentText, agentOK, steps, files) = await runAgent(env, "Make a CSV of the 3 biggest Indian IT companies by annual revenue (company, revenue in USD billions, fiscal year) and save it.")
        if agentOK, let f = files.first(where: { $0.pathExtension == "csv" }) {
            let csv = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            pass("agent CSV task", "\(steps.count) steps [\(steps.joined(separator: ", "))] → \(f.lastPathComponent): \(csv.replacingOccurrences(of: "\r\n", with: " / ").prefix(160))")
        } else { fail("agent CSV task", "ok=\(agentOK) steps=\(steps) summary=\"\(agentText.prefix(150))\"") }
        for f in files where !before.contains(f.lastPathComponent) { try? FileManager.default.removeItem(at: f) }

        // 9) Buddy + routine creation by conversation, then run the routine now
        let (bText, bOK, bSteps, _) = await runAgent(env, "Make me a buddy that summarizes my day every evening at 9.")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let newBuddies = env.buddies.buddies.filter { !["General Helper", "Tutor"].contains($0.name) }
        if bOK, let nb = newBuddies.last, let routine = env.buddies.routines(for: nb).first {
            pass("buddy by conversation", "\"\(nb.name)\" routine=\(Schedule.parse(routine.schedule)?.label ?? routine.schedule) next=\(routine.nextRunAt.map { "\($0)" } ?? "nil") steps=\(bSteps)")
            let runner = AgentRunner(gemini: env.gemini, settings: env.settings, usage: env.usage, memory: env.memory, db: env.db)
            runner.extraTools = { BuddyTools.make(store: env.buddies, scheduler: env.scheduler, wiki: env.wiki) + env.mcp.agentTools }
            let summary: String = await withCheckedContinuation { cont in
                runner.onFinished = { s, _, _ in cont.resume(returning: s) }
                runner.start(task: routine.prompt, buddy: nb, headless: true)
            }
            if case .done = runner.status { pass("routine run (headless)", "\"\(summary.prefix(160))\"") }
            else { fail("routine run (headless)", "\(runner.status) \"\(summary.prefix(120))\"") }
        } else { fail("buddy by conversation", "ok=\(bOK) buddies=\(newBuddies.map(\.name)) steps=\(bSteps) \"\(bText.prefix(120))\"") }
        for b in newBuddies {   // cleanup
            if let bid = b.id { _ = try? await env.db.writer.write { try $0.execute(sql: "DELETE FROM buddy WHERE id = ?", arguments: [bid]) } }
            try? FileManager.default.removeItem(atPath: b.folderPath)
        }
        _ = try? await env.db.writer.write { try $0.execute(sql: "DELETE FROM conversation WHERE kind='buddy' AND buddyId IS NULL") }

        // 10) Computer use: ui_read on the frontmost app (read-only)
        let ctx = ToolContext(outputFolder: BuddyStore.folder(for: "General Helper"), allowedFolders: [], gemini: env.gemini, searchModel: env.settings.data.fastModel, fallbackModel: env.settings.data.cheapModel)
        if let r = try? await ComputerUse.read.run([:], ctx) {
            let n = r.text.split(separator: "\n").filter { $0.hasPrefix("[") }.count
            n > 0 ? pass("computer use ui_read", "\(n) elements, screenshot=\(r.image != nil) · \(r.text.split(separator: "\n").first ?? "")")
                  : fail("computer use ui_read", r.text.prefix(150).description)
        }

        // 11) Notes wiki + skills drafting
        let url = env.wiki.save(topic: "Sidekick feature test", content: "Testing the notes wiki.")
        FileManager.default.fileExists(atPath: url.path) ? pass("notes wiki save") : fail("notes wiki save", "file missing")
        try? FileManager.default.removeItem(at: url); env.wiki.reload()
        let skillReq = GeminiRequest(model: env.settings.data.cheapModel, system: "Write a 2-line instruction for an assistant skill.", turns: [GeminiTurn(role: .user, text: "answer like a pirate")], thinkingLevel: "low", maxOutputTokens: 200)
        if let (t, _) = try? await env.gemini.complete(skillReq), !t.isEmpty { pass("skill drafting (fast model)") } else { fail("skill drafting", "no text") }

        // 12) Quiet mode, usage
        env.quiet.evaluate()
        info("quiet mode", env.quiet.isQuiet ? "ON (mic busy / sharing / focus)" : "off")
        let usage = (try? await env.db.usage(since: CostMeter.dayKey(Date()))) ?? []
        info("usage today", usage.map { "\($0.model): \($0.inputTokens) in / \($0.outputTokens) out ≈ $\(String(format: "%.4f", $0.costUSD))" }.joined(separator: "; "))

        env.settings.data.textOnly = savedTextOnly
        env.coordinator.onTag = nil
        env.coordinator.onTurnFinished = savedTurnHook
        env.memory.setProfile(memBackup.0); env.memory.setVolatile(memBackup.1)
        print("FT DONE"); fflush(stdout)
        NSApp.terminate(nil)
    }

    static func runAgent(_ env: AppEnvironment, _ task: String) async -> (String, Bool, [String], [URL]) {
        let runner = AgentRunner(gemini: env.gemini, settings: env.settings, usage: env.usage, memory: env.memory, db: env.db)
        runner.extraTools = { BuddyTools.make(store: env.buddies, scheduler: env.scheduler, wiki: env.wiki) + env.mcp.agentTools }
        let t0 = Date()
        let summary: String = await withCheckedContinuation { cont in
            runner.onFinished = { s, _, _ in cont.resume(returning: s) }
            runner.start(task: task, headless: true)
        }
        var ok = false
        if case .done = runner.status { ok = true }
        let steps = runner.steps.map { "\($0.title.prefix(40))(\($0.state))" } + ["\(Int(Date().timeIntervalSince(t0)))s"]
        return (summary, ok, steps, runner.files)
    }
}

/// `Sidekick -geminiProbe YES`: raw status/message for small requests in several shapes.
@MainActor
enum GeminiProbe {
    static func run(env: AppEnvironment) async {
        let key = Keychain.get(Keychain.geminiAccount) ?? ""
        let fast = env.settings.data.fastModel
        let shot = try? await env.capturer.capture(readBrowserURL: false)
        func body(_ think: String?, image: Bool) -> Data {
            var parts: [[String: Any]] = []
            if image, let j = shot?.jpeg { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": j.base64EncodedString()]]) }
            parts.append(["text": "Say hi in 3 words."])
            var gen: [String: Any] = ["maxOutputTokens": 64]
            if let think { gen["thinkingConfig"] = ["thinkingLevel": think] }
            return try! JSONSerialization.data(withJSONObject: ["contents": [["role": "user", "parts": parts]], "generationConfig": gen])
        }
        // Which models does this key list, and how fast is each at a screenshot question?
        var listReq = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
        listReq.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if let (d, _) = try? await URLSession.shared.data(for: listReq),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = j["models"] as? [[String: Any]] {
            let names = ms.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                .filter { $0.contains("flash") || $0.contains("pro") }
            print("PROBE models: " + names.joined(separator: ", "))
        }
        if UserDefaults.standard.bool(forKey: "probeLatency") {
            let candidates = (UserDefaults.standard.string(forKey: "probeModels") ?? "").split(separator: ",").map(String.init)
            for m in candidates {
                for think in [nil, "minimal", "low"] as [String?] {
                    var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):streamGenerateContent?alt=sse")!)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    var b = try! JSONSerialization.jsonObject(with: body(think, image: true)) as! [String: Any]
                    var g = b["generationConfig"] as! [String: Any]; g["maxOutputTokens"] = 256; b["generationConfig"] = g
                    b["contents"] = [["role": "user", "parts": [["inlineData": ["mimeType": "image/jpeg", "data": shot?.jpeg.base64EncodedString() ?? ""]], ["text": "What app is in front? One short sentence."]]]]
                    req.httpBody = try! JSONSerialization.data(withJSONObject: b)
                    let t0 = Date()
                    var first: Int?
                    var text = ""
                    var code = 0
                    do {
                        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                        code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        if code == 200 {
                            for try await line in bytes.lines {
                                if let c = SSEParser.parse(line: line), !c.text.isEmpty {
                                    if first == nil { first = Int(Date().timeIntervalSince(t0) * 1000) }
                                    text += c.text
                                }
                            }
                        } else {
                            var d = Data(); for try await x in bytes { d.append(x); if d.count > 1500 { break } }
                            text = String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                        }
                    } catch { text = error.localizedDescription }
                    print("PROBE \(m) think=\(think ?? "none"): \(code) first-token=\(first.map { "\($0)ms" } ?? "-") total=\(Int(Date().timeIntervalSince(t0) * 1000))ms · \(text.prefix(code == 200 ? 80 : 700))")
                    fflush(stdout)
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
            print("PROBE DONE"); fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        let cases: [(String, String, String?, Bool, Bool)] = [
            ("fast · no thinking · text", fast, nil, false, false),
            ("fast · minimal · text", fast, "minimal", false, false),
            ("fast · low · text", fast, "low", false, false),
            ("fast · minimal · image", fast, "minimal", true, false),
            ("fast · minimal · image · SSE", fast, "minimal", true, true),
            ("smart · low · image · SSE", env.settings.data.smartModel, "low", true, true),
            ("cheap · none · text", env.settings.data.cheapModel, nil, false, false),
        ]
        for (name, model, think, image, sse) in cases {
            let path = sse ? "models/\(model):streamGenerateContent?alt=sse" : "models/\(model):generateContent"
            var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/" + path)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = body(think, image: image)
            let t0 = Date()
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let retry = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "-"
                let text = String(decoding: data.prefix(600), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                print("PROBE \(name): \(code) in \(Int(Date().timeIntervalSince(t0) * 1000))ms retry-after=\(retry) · \(code == 200 ? String(text.prefix(140)) : text)")
            } catch { print("PROBE \(name): error \(error.localizedDescription)") }
            fflush(stdout)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        print("PROBE DONE"); fflush(stdout)
        NSApp.terminate(nil)
    }
}

/// `Sidekick -langProbe YES`: does the chat prompt make the lite model drift into Hinglish?
@MainActor
enum LangProbe {
    static func run(env: AppEnvironment) async {
        let template = (Bundle.main.url(forResource: "chat", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let ctx = PromptBuilder.Context(profile: "", volatile: "- [2026-10-01] Working on Java code.", activeSkills: env.skills.promptText(for: "x"),
                                        appName: "Finder", windowTitle: nil, url: nil)
        let current = PromptBuilder.system(template: template, context: ctx)
        let noExample = current.replacingOccurrences(of: "Match the language of the user's own message (Hinglish if they write Hinglish), not the language of attachments or their screen.",
                                                     with: "Reply in the same language as the user's latest message.")
        _ = noExample
        let variants: [(String, String, String)] = [
            ("english question", current, "can you help me java codes?"),
            ("hinglish question", current, "mujhe java mein ek loop likhna hai, help karo"),
        ]
        for (name, system, text) in variants {
            for i in 1...3 {
                let req = GeminiRequest(model: env.settings.data.cheapModel, system: system,
                                        turns: [GeminiTurn(role: .user, text: "what's on my screen?"),
                                                GeminiTurn(role: .model, text: "Your Mac desktop, showing wallpaper with mountains and a sheep."),
                                                GeminiTurn(role: .user, text: text)],
                                        thinkingLevel: "off", maxOutputTokens: 120)
                let out = (try? await env.gemini.complete(req).text) ?? "(error)"
                print("LANG \(name) #\(i) [\(VoiceSelector.language(of: out))]: \(out.replacingOccurrences(of: "\n", with: " ").prefix(90))")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
        print("LANG DONE"); fflush(stdout)
        NSApp.terminate(nil)
    }
}

/// `Sidekick -voiceProbe /path/prefix`: synthesizes samples with the natural voices, prints timings,
/// writes WAVs (prefix-en.wav, prefix-hi.wav) for checking, and exits.
enum VoiceProbe {
    static func run(prefix: String) async {
        func save(_ samples: [Float], rate: Double, to path: String) {
            guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(samples.count)),
                  let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: f.settings) else { return }
            b.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try? file.write(from: b)
        }
        func ms(_ t: CFAbsoluteTime) -> Int { Int((CFAbsoluteTimeGetCurrent() - t) * 1000) }
        await Task.detached {
            var t = CFAbsoluteTimeGetCurrent()
            guard let en = NeuralVoiceModel.kokoro(at: NeuralTTS.kokoroDir) else { print("VOICE FAIL kokoro load"); exit(1) }
            print("VOICE kokoro load \(ms(t)) ms, speakers \(en.speakers), rate \(en.sampleRate)")
            _ = en.generate("Hi.", sid: 3, speed: 1)
            let line = "Hey Mayank! Apple Music is open now. Want me to put on something relaxing?"
            t = CFAbsoluteTimeGetCurrent()
            let s1 = en.generate("Hey Mayank! Apple Music is open now.", sid: 3, speed: 0.96)
            print("VOICE first sentence \(ms(t)) ms for \(String(format: "%.1f", Double(s1.count) / en.sampleRate)) s of audio")
            save(en.generate(line, sid: 3, speed: 0.96), rate: en.sampleRate, to: prefix + "-en.wav")
            t = CFAbsoluteTimeGetCurrent()
            if let hi = NeuralVoiceModel.piper(at: NeuralTTS.hindiDir, model: NeuralTTS.hindiModel) {
                print("VOICE hindi load \(ms(t)) ms")
                t = CFAbsoluteTimeGetCurrent()
                let h = hi.generate("नमस्ते! मैंने एप्पल म्यूज़िक खोल दिया है। कुछ सुनना चाहोगे?", sid: 0, speed: 0.96)
                print("VOICE hindi sentence \(ms(t)) ms for \(String(format: "%.1f", Double(h.count) / hi.sampleRate)) s")
                save(h, rate: hi.sampleRate, to: prefix + "-hi.wav")
            } else { print("VOICE FAIL hindi load") }
        }.value
        print("VOICE DONE")
        exit(0)
    }
}

/// `Sidekick -talkProbe "question"`: two real turns through the voice pipeline (speech muted), printing
/// the reply, model note and timings — checks the model fallback chain end to end.
@MainActor
enum TalkProbe {
    static var question = ""

    @inline(never)
    static func run(env: AppEnvironment) async {
        let question = Self.question
        let aloud = UserDefaults.standard.bool(forKey: "talkAloud")
        env.coordinator.silenced = !aloud
        env.coordinator.onTurnFinished = nil
        if aloud { env.coordinator.prewarm(); try? await Task.sleep(nanoseconds: 3_000_000_000) }
        // "first|second" asks a short conversation (one turn each) instead of the same question twice.
        let parts = question.components(separatedBy: "|").filter { !$0.isEmpty }
        let isConversation = parts.count > 1
        var questions: [String] = []
        if isConversation { questions.append(contentsOf: parts) } else { questions.append(question); questions.append(question) }
        for (n, q) in questions.enumerated() {
            let i = n + 1
            let t = CFAbsoluteTimeGetCurrent()
            print("TALK #\(i) you: \(q)")
            await env.coordinator.askText(q)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t) * 1000)
            let reply = env.state.reply.replacingOccurrences(of: "\n", with: " ")
            var phase = ""
            if case .message(let m) = env.state.phase { phase = "MESSAGE: " + m }
            print("TALK #\(i) \(ms) ms · note=\(env.state.modelNote ?? "-") · \(phase.isEmpty ? "reply: " + reply.prefix(140) : phase)")
            for _ in 0..<80 where aloud && env.coordinator.isSpeaking { try? await Task.sleep(nanoseconds: 250_000_000) }
            if aloud { print("TALK #\(i) natural voice used: \(env.coordinator.tts.neural.failed ? "no (fell back)" : "yes") · release→first word=\(env.state.timings["release→first word"].map(String.init) ?? "-") ms") }
            for _ in 0..<60 where env.agent.isActive { try? await Task.sleep(nanoseconds: 500_000_000) }
            if !env.agent.steps.isEmpty {
                print("TALK #\(i) agent \(env.agent.status): " + env.agent.steps.map(\.title).joined(separator: " | "))
            }
            if UserDefaults.standard.bool(forKey: "talkOnce"), !isConversation { print("TALK DONE"); fflush(stdout); exit(0) }
            print("TALK #\(i) timings \(env.state.timings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            fflush(stdout)
        }
        print("TALK DONE"); fflush(stdout)
        exit(0)
    }
}

/// `Sidekick -searchProbe "query"`: runs web_search grounding on each configured model and prints the outcome.
@MainActor
enum SearchProbe {
    static func run(env: AppEnvironment, query: String) async {
        for model in [env.settings.data.fastModel, env.settings.data.cheapModel, env.settings.data.smartModel] {
            let ctx = ToolContext(outputFolder: FileManager.default.temporaryDirectory, allowedFolders: [], gemini: env.gemini, searchModel: model)
            let t = CFAbsoluteTimeGetCurrent()
            do {
                let r = try await WebTools.search.run(["query": query], ctx)
                print("SEARCH \(model) OK \(Int((CFAbsoluteTimeGetCurrent() - t) * 1000))ms: \(r.text.replacingOccurrences(of: "\n", with: " ").prefix(160))")
            } catch {
                print("SEARCH \(model) FAIL: \(error) — \(error.localizedDescription)".prefix(400))
            }
            fflush(stdout)
        }
        print("SEARCH DONE"); fflush(stdout)
        exit(0)
    }
}

/// `Sidekick -memoryProbe YES`: runs the real memory updater on a throwaway memory folder and prints the result.
@MainActor
enum MemoryProbe {
    static func run(env: AppEnvironment) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memprobe-\(UUID().uuidString)")
        let store = MemoryStore(directory: dir)
        let mu = MemoryUpdater(memory: store, gemini: env.gemini, settings: env.settings, usage: env.usage)
        mu.record(ConversationTurn(user: "Remember: I'm Mayank, I study computer science, my friend Rahul works in IT, I love lofi music, and I like detailed step-by-step math answers. Right now I'm prepping for a C++ exam.",
                                   assistant: "Got it, Mayank!"))
        for _ in 0..<40 where store.profile.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
        print("MEM PROFILE:\n\(store.profile)\nMEM VOLATILE:\n\(store.volatile)\nMEM DONE")
        fflush(stdout)
        try? FileManager.default.removeItem(at: dir)
        exit(0)
    }
}

/// `Sidekick -sttProbe a.wav,b.wav`: runs files through the exact voice-turn steps (silence trim → length gate →
/// Whisper → clean-up) with 0.6 s of silence around them (like holding the key), at normal and quiet volume.
@MainActor
enum STTProbe {
    static func load(_ path: String) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: f.processingFormat, to: fmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
        try? f.read(into: inBuf)
        let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(f.length) * 16_000 / f.processingFormat.sampleRate) + 1024)!
        var fed = false
        _ = conv.convert(to: outBuf, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    static func run(env: AppEnvironment, files: [String]) async {
        env.loadWhisper(env.settings.data.whisperModel)
        for _ in 0..<120 where !(await env.stt.isReady) { try? await Task.sleep(nanoseconds: 250_000_000) }
        let silence = [Float](repeating: 0, count: 9_600)
        for path in files {
            guard let clip = load(path) else { print("STT \(path): can't read"); continue }
            for gain: Float in [1.0, 0.25] {
                let samples = silence + clip.map { $0 * gain } + silence
                let out = await env.coordinator.transcribeForProbe(samples)
                print("STT \((path as NSString).lastPathComponent) gain=\(gain): \(out)")
                fflush(stdout)
            }
        }
        print("STT DONE"); fflush(stdout)
        exit(0)
    }
}

/// `Sidekick -typeProbe "text"`: types into whatever is focused (after 1.5 s) with the agent's typing path, then exits.
@MainActor
enum TypeProbe {
    static var text = ""
    @inline(never)
    static func run() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await ComputerUse.synthType(text)
        try? await Task.sleep(nanoseconds: 500_000_000)
        print("TYPE DONE"); fflush(stdout)
        exit(0)
    }
}

/// `Sidekick -ocrProbe YES`: screenshot + on-screen names (the Whisper hints), with timings.
@MainActor
enum OCRProbe {
    @inline(never)
    static func run(env: AppEnvironment) async {
        let tw = CFAbsoluteTimeGetCurrent()
        Vocabulary.prewarm()
        print("OCR prewarm \(Int((CFAbsoluteTimeGetCurrent() - tw) * 1000))ms")
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let shot = try? await env.capturer.capture(readBrowserURL: false) else { print("OCR capture failed"); exit(1) }
        let t1 = CFAbsoluteTimeGetCurrent()
        let names = Vocabulary.fromScreen(shot.image)
        let t2 = CFAbsoluteTimeGetCurrent()
        print("OCR app=\(shot.appName ?? "?") capture=\(Int((t1 - t0) * 1000))ms ocr=\(Int((t2 - t1) * 1000))ms")
        print("OCR names: " + names.joined(separator: " | "))
        print("OCR prompt: " + (Vocabulary.prompt(screen: names, memory: [], dictionary: []) ?? "-"))
        fflush(stdout)
        exit(0)
    }
}
