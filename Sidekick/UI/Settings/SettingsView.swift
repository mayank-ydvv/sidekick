import SwiftUI
import AVFoundation
import Charts

struct SettingsView: View {
    let env: AppEnvironment

    var body: some View {
        TabView {
            GeneralTab(env: env).tabItem { Label("general", systemImage: "gearshape") }
            ShortcutsTab(env: env).tabItem { Label("shortcuts", systemImage: "keyboard") }
            VoiceTab(env: env).tabItem { Label("voice", systemImage: "waveform") }
            AITab(env: env).tabItem { Label("ai", systemImage: "sparkles") }
            MemoryTab(env: env).tabItem { Label("memory", systemImage: "brain") }
            DictionaryTab(env: env).tabItem { Label("dictionary", systemImage: "character.book.closed") }
            SkillsTab(env: env).tabItem { Label("skills", systemImage: "wand.and.stars") }
            BuddiesTab(env: env).tabItem { Label("buddies", systemImage: "person.2") }
            ConnectionsTab(env: env).tabItem { Label("connections", systemImage: "point.3.connected.trianglepath.dotted") }
            UsageTab(env: env).tabItem { Label("usage", systemImage: "chart.bar") }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }
}

private struct GeneralTab: View {
    let env: AppEnvironment
    var body: some View {
        @Bindable var s = env.settings
        Form {
            LabeledContent("push to talk") { Text("hold \(s.data.pushToTalk.symbols) · change in shortcuts") }
            LabeledContent("dictation") { Text("hold \(s.data.dictateKeys.symbols) · double-tap for hands-free") }
            Toggle("polish dictation with ai (uses the cheap model)", isOn: $s.data.polishDictation)
            Toggle("read the browser url for context", isOn: $s.data.readBrowserURL)
            Toggle("launch at login", isOn: $s.data.launchAtLogin)
                .onChange(of: s.data.launchAtLogin) { _, _ in env.applyLaunchAtLogin() }
            Toggle("quick peek when hovering the notch", isOn: $s.data.peekOnHover)
            Toggle("quiet mode on calls, screen sharing and focus", isOn: $s.data.quietMode)
            Toggle("let tasks run without asking (risky commands still ask)", isOn: $s.data.autoApprove)
            CalendarAccessRow()
            Toggle("morning suggestions (reads calendar & connections, opt-in)", isOn: $s.data.proactiveSuggestions)
            if s.data.proactiveSuggestions {
                Toggle("also in the afternoon", isOn: $s.data.afternoonSuggestions)
            }
            Toggle("show buddy next to the cursor", isOn: $s.data.showBuddy)
            Toggle("show the reply as text next to the cursor", isOn: $s.data.showCursorBubble)
                .onChange(of: s.data.showBuddy) { _, _ in env.coordinator.overlay.settingsChanged() }
            Toggle("dock buddy in the notch", isOn: $s.data.dockBuddy)
                .onChange(of: s.data.dockBuddy) { _, _ in env.coordinator.overlay.settingsChanged() }
            LabeledContent("hotkey") {
                Text(env.state.hotkeyInstalled ? "active" : "needs accessibility permission")
                    .foregroundStyle(env.state.hotkeyInstalled ? .green : .orange)
            }
            Button("open setup again") { env.showOnboarding() }
            Section("folders agents may use") {
                Text("agents always save into ~/Sidekick/Buddies. add other folders they may read and write:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(s.data.agentFolders, id: \.self) { f in
                    HStack {
                        Text(f).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { s.data.agentFolders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("remove folder")
                    }
                }
                Button("add folder…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url, !s.data.agentFolders.contains(u.path) { s.data.agentFolders.append(u.path) }
                }
            }
            Section("privacy") {
                Text("screenshots are never saved. chats, memory and the dictionary stay on this mac.")
                    .font(.caption).foregroundStyle(.secondary)
                DeleteAllButton(env: env)
            }
            Section("last run (ms)") {
                ForEach(env.state.timings.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    LabeledContent(k) { Text("\(v)").monospacedDigit() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoiceTab: View {
    let env: AppEnvironment
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        @Bindable var s = env.settings
        Form {
            Section("listening") {
                Picker("speech model", selection: $s.data.whisperModel) {
                    ForEach(WhisperModel.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: s.data.whisperModel) { _, m in env.loadWhisper(m) }
                WhisperStatusView(state: env.state.whisper)
                TextField("language (blank = auto, e.g. en, hi)", text: $s.data.language)
            }
            Section("speaking") {
                if NeuralTTS.isInstalled {
                    Toggle("natural voice (offline, soft & human-like)", isOn: $s.data.naturalVoice)
                }
                if NeuralTTS.isInstalled, s.data.naturalVoice {
                    Picker("voice", selection: $s.data.naturalVoiceName) {
                        ForEach(NeuralTTS.voices) { Text($0.label).tag($0.name) }
                    }
                    if NeuralTTS.hindiInstalled {
                        LabeledContent("hindi replies") { Text("Priyamvada (soft, Indian)") }
                    }
                } else {
                    Picker("voice", selection: $s.data.ttsVoiceID) {
                        Text("system default").tag(String?.none)
                        ForEach(voices, id: \.identifier) { v in
                            Text(v.name + (v.quality == .premium ? " ★★" : v.quality == .enhanced ? " ★" : "") + "  (\(v.language))")
                                .tag(Optional(v.identifier))
                        }
                    }
                    Slider(value: $s.data.ttsPitch, in: 0.7...1.4) { Text("pitch") }
                }
                Slider(value: $s.data.ttsRate, in: 0.35...0.65) { Text("speed") }
                Slider(value: $s.data.ttsVolume, in: 0...1) { Text("volume") }
                Toggle("show text only (no voice)", isOn: $s.data.textOnly)
                Button("hear a sample") { env.coordinator.previewVoice() }
            }
        }
        .formStyle(.grouped)
        .onAppear { if voices.isEmpty { voices = SystemTTS.installedVoices() } }
    }
}

private struct AITab: View {
    let env: AppEnvironment
    @State private var newKey = ""

    var body: some View {
        @Bindable var s = env.settings
        Form {
            Section("api key") {
                HStack {
                    SecureField(env.state.hasAPIKey ? "•••••••• (saved)" : "gemini api key", text: $newKey)
                    Button("save") { env.saveAPIKey(newKey); newKey = "" }.disabled(newKey.isEmpty)
                    if env.state.hasAPIKey { Button("remove", role: .destructive) { env.removeAPIKey() } }
                }
            }
            Section("models") {
                TextField("fast", text: $s.data.fastModel)
                TextField("smart", text: $s.data.smartModel)
                TextField("cheap", text: $s.data.cheapModel)
                Picker("which model answers", selection: $s.data.modelTier) {
                    Text("auto (fast, smart when needed)").tag(ModelTier.auto)
                    Text("always fast").tag(ModelTier.fast)
                    Text("always smart").tag(ModelTier.smart)
                }
                Picker("thinking level (fast)", selection: $s.data.thinkingLevel) {
                    ForEach(["off", "minimal", "low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
                Picker("thinking level (smart)", selection: $s.data.smartThinkingLevel) {
                    ForEach(["off", "minimal", "low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
            }
            Section("prices (usd per 1m tokens)") {
                ForEach([s.data.fastModel, s.data.smartModel, s.data.cheapModel], id: \.self) { m in
                    PriceRow(model: m, settings: env.settings)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PriceRow: View {
    let model: String
    let settings: AppSettings
    var body: some View {
        let price = settings.data.prices[model] ?? ModelPrice(inputPerMillion: 0.5, outputPerMillion: 3.0)
        HStack {
            Text(model).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            TextField("in", value: Binding(get: { price.inputPerMillion },
                                          set: { settings.data.prices[model, default: price].inputPerMillion = $0 }),
                      format: .number).frame(width: 60)
            TextField("out", value: Binding(get: { price.outputPerMillion },
                                           set: { settings.data.prices[model, default: price].outputPerMillion = $0 }),
                      format: .number).frame(width: 60)
        }
    }
}

private struct UsageTab: View {
    let env: AppEnvironment
    @State private var rows: [UsageDailyRecord] = []

    var body: some View {
        @Bindable var s = env.settings
        let today = env.usage.meter.today()
        let monthCost = rows.reduce(0) { $0 + $1.costUSD }
        Form {
            Section("today") {
                LabeledContent("input tokens") { Text("\(today.inputTokens)").monospacedDigit() }
                LabeledContent("output tokens") { Text("\(today.outputTokens)").monospacedDigit() }
                LabeledContent("estimated cost") { Text(today.costUSD, format: .currency(code: "USD").precision(.fractionLength(4))) }
            }
            Section("this month · \(monthCost.formatted(.currency(code: "USD").precision(.fractionLength(2))))") {
                if rows.isEmpty {
                    Text("no usage yet").foregroundStyle(.secondary)
                } else {
                    Chart(rows, id: \.date) { r in
                        BarMark(x: .value("day", String(r.date.suffix(2))), y: .value("usd", r.costUSD))
                            .foregroundStyle(by: .value("model", r.model))
                    }
                    .frame(height: 140)
                }
            }
            Section("budget") {
                TextField("daily budget (usd)", value: $s.data.dailyBudgetUSD, format: .number)
                Toggle("stop at 100% of budget", isOn: $s.data.hardStopAtBudget)
                Text("you'll get a warning at 80%.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let start = String(CostMeter.dayKey(Date()).prefix(8)) + "01"
            rows = (try? await env.db.usage(since: start)) ?? []
        }
    }
}

private struct MemoryTab: View {
    let env: AppEnvironment
    @State private var profile = ""
    @State private var volatile = ""
    @State private var confirm = false

    var body: some View {
        Form {
            Section("about you (PROFILE.md)") {
                TextEditor(text: $profile).font(.system(size: 12, design: .monospaced)).frame(height: 120)
            }
            Section("right now (VOLATILE.md — items expire after 7 days)") {
                TextEditor(text: $volatile).font(.system(size: 12, design: .monospaced)).frame(height: 90)
            }
            HStack {
                Button("save") { env.memory.setProfile(profile); env.memory.setVolatile(volatile) }
                    .disabled(profile == env.memory.profile && volatile == env.memory.volatile)
                Button("show in finder") { NSWorkspace.shared.activateFileViewerSelecting([env.memory.profileURL]) }
                Spacer()
                Button("delete all memory", role: .destructive) { confirm = true }
            }
            Text("tip: say \"remember that…\" or \"forget that…\" anytime.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { profile = env.memory.profile; volatile = env.memory.volatile }
        .confirmationDialog("delete everything sidekick remembers about you?", isPresented: $confirm) {
            Button("delete memory", role: .destructive) { env.memory.deleteAll(); profile = ""; volatile = "" }
        }
    }
}

private struct DeleteAllButton: View {
    let env: AppEnvironment
    @State private var confirm = false
    var body: some View {
        Button("delete all data…", role: .destructive) { confirm = true }
            .confirmationDialog("delete all chats, memory, dictionary, usage and your api key?", isPresented: $confirm) {
                Button("delete everything", role: .destructive) { env.deleteAllData() }
            } message: { Text("this can't be undone.") }
    }
}

private struct DictionaryTab: View {
    let env: AppEnvironment
    @State private var wrong = ""
    @State private var right = ""

    var body: some View {
        Form {
            Section {
                Text("when you fix a word i typed, i learn it. these spellings also help me hear names and jargon.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("heard as", text: $wrong)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("should be", text: $right)
                    Button("add") {
                        env.dictionary.learn(wrong: wrong, right: right)
                        wrong = ""; right = ""
                    }.disabled(wrong.isEmpty || right.isEmpty)
                }
            }
            Section("learned words") {
                if env.dictionary.entries.isEmpty {
                    Text("nothing yet").foregroundStyle(.secondary)
                }
                ForEach(env.dictionary.entries) { e in
                    HStack {
                        Text(e.wrong).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(e.right)
                        Spacer()
                        Text("×\(e.hits)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        Button { env.dictionary.remove(e) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("remove \(e.wrong)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Calendar + Reminders access for tasks and routines (the system shows its own Allow dialog).
private struct CalendarAccessRow: View {
    @State private var calendar = AppleTools.accessDescription(.event)
    @State private var reminders = AppleTools.accessDescription(.reminder)
    var body: some View {
        LabeledContent("calendar & reminders") {
            HStack {
                Text("calendar: \(calendar) · reminders: \(reminders)").foregroundStyle(.secondary)
                if calendar != "granted" || reminders != "granted" {
                    Button(calendar == "denied" || reminders == "denied" ? "open privacy settings" : "allow") {
                        if calendar == "denied" || reminders == "denied" {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        } else {
                            Task {
                                _ = await AppleTools.requestAccess(.event)
                                _ = await AppleTools.requestAccess(.reminder)
                                calendar = AppleTools.accessDescription(.event)
                                reminders = AppleTools.accessDescription(.reminder)
                            }
                        }
                    }
                }
            }
        }
    }
}
