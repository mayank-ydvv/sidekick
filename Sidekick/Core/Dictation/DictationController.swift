import AppKit

/// Hold Fn+Control to dictate into any app; double-tap for hands-free (tap again or 3 s of silence to stop).
/// Never calls Gemini unless "polish with ai" is turned on.
@MainActor
final class DictationController {
    enum Mode: Equatable { case idle, holding, handsFree, processing }

    private let state: AppState
    private let settings: AppSettings
    private let audio: AudioCapture
    private let stt: WhisperKitSTT
    private let gemini: GeminiClient
    private let usage: UsageStore
    let dictionary: PersonalDictionary
    private let inserter = TextInserter()
    private let watcher = CorrectionWatcher()
    private let hud: DictationHUD

    private(set) var mode: Mode = .idle
    private var taps = TapCounter()
    private var startedAt: TimeInterval = 0
    private var lastVoiceAt: TimeInterval = 0
    private var heardVoice = false
    private var work: Task<Void, Never>?

    /// Lets the talk coordinator know the mic is busy.
    var isBusy: Bool { mode != .idle }

    /// UI tests: transcribe but never type into another app.
    var dryRun = false
    private(set) var lastDryRunText: String?

    static let silenceStop: TimeInterval = 3
    static let noSpeechStop: TimeInterval = 8
    static let voiceLevel: Float = 0.08

    init(state: AppState, settings: AppSettings, audio: AudioCapture, stt: WhisperKitSTT, gemini: GeminiClient, usage: UsageStore, dictionary: PersonalDictionary) {
        self.state = state
        self.settings = settings
        self.audio = audio
        self.stt = stt
        self.gemini = gemini
        self.usage = usage
        self.dictionary = dictionary
        self.hud = DictationHUD(state: state)
        watcher.onLearn = { [weak dictionary] w, r in dictionary?.learn(wrong: w, right: r) }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func handle(_ e: HotkeyEvent) {
        switch (e, mode) {
        case (.armed, .idle):
            startRecording()
        case (.armed, .handsFree):
            break   // a tap while hands-free stops it (on .tap below)
        case (.began, .idle), (.began, .holding):
            mode = .holding
            showHUD(handsFree: false)
        case (.ended, .holding):
            finish()
        case (.tap, .handsFree):
            finish()
        case (.tap, .idle):
            // Quick tap: maybe the first half of a double-tap.
            if taps.tap(at: now) >= 2 {
                taps.reset()
                startRecording()
                mode = .handsFree
                showHUD(handsFree: true)
            } else {
                stopAudio()
            }
        case (.cancelled, .idle):
            stopAudio()
        default:
            break
        }
    }

    private func startRecording() {
        guard !audio.isRunning else { return }
        do { try audio.start() } catch {
            Log.audio.error("dictation audio failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        startedAt = now
        heardVoice = false
        audio.onLevel = { [weak self] lvl in self?.levelChanged(lvl) }
    }

    private func levelChanged(_ lvl: Float) {
        state.dictationLevel = lvl
        guard mode == .handsFree else { return }
        let t = now
        if lvl >= Self.voiceLevel { heardVoice = true; lastVoiceAt = t }
        if (heardVoice && t - lastVoiceAt >= Self.silenceStop) || (!heardVoice && t - startedAt >= Self.noSpeechStop) {
            finish()
        }
    }

    /// Stops the mic and gives the level callback back to the talk pipeline.
    private func stopAudio() {
        audio.stop()
        audio.onLevel = { [weak state] lvl in state?.level = lvl }
    }

    private func showHUD(handsFree: Bool) {
        state.dictation = handsFree ? .handsFree : .holding
        hud.show()
    }

    private func finish() {
        let samples = audio.stop()
        audio.onLevel = { [weak state] lvl in state?.level = lvl }
        mode = .processing
        state.dictation = .processing
        work = Task { [weak self] in
            await self?.process(samples)
            self?.mode = .idle
            self?.state.dictation = .idle
            self?.hud.hide()
        }
    }

    func cancel() {
        work?.cancel()
        if audio.isRunning { stopAudio() }
        mode = .idle
        state.dictation = .idle
        hud.hide()
    }

    private func process(_ samples: [Float]) async {
        let trimmed = VAD.trimSilence(samples)
        guard trimmed.count >= Int(AudioCapture.sampleRate * 0.25), await stt.isReady else { return }
        let lang = settings.data.language.isEmpty ? nil : settings.data.language
        guard let raw = try? await stt.transcribe(trimmed, language: lang, prompt: dictionary.promptWords) else { return }
        var text = TalkCoordinator.cleanTranscript(raw)
        guard text.count >= 2, !Task.isCancelled else { return }
        text = dictionary.apply(TextCleaner.clean(text))
        if settings.data.polishDictation, !dryRun { text = await polish(text) }
        if dryRun { lastDryRunText = text; return }
        guard !Task.isCancelled, let result = await inserter.insert(text) else { return }
        watcher.watch(result)
    }

    /// Optional Flash-Lite cleanup with a short timeout; falls back to the local text.
    private func polish(_ text: String) async -> String {
        let model = settings.data.cheapModel
        let req = GeminiRequest(
            model: model,
            system: "You clean up dictated text. Fix punctuation, capitalization and obvious grammar slips. Keep the wording, tone and language (including Hinglish). Output only the cleaned text, nothing else.",
            turns: [GeminiTurn(role: .user, text: text)],
            thinkingLevel: "minimal",
            maxOutputTokens: 1024
        )
        let gemini = gemini
        let collect = Task { () -> (String, TokenUsage?) in
            var out = ""
            var u: TokenUsage?
            for try await c in gemini.stream(req) { out += c.text; if let cu = c.usage { u = cu } }
            return (out, u)
        }
        let timeout = Task { try await Task.sleep(nanoseconds: 3_000_000_000); collect.cancel() }
        defer { timeout.cancel() }
        guard let (out, u) = try? await collect.value else { return text }
        if let u { usage.record(model: model, usage: u) }
        let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }

    /// Screen-aware writing: the talk model emitted [TYPE text="..."].
    func type(_ text: String) {
        Task { [inserter] in _ = await inserter.insert(text) }
    }

    /// Replaces the user's selection / focused field (e.g. with a spelling- and grammar-corrected version).
    func replace(_ text: String, expectedApp: pid_t?) async -> Bool {
        await inserter.replace(with: text, expectedApp: expectedApp)
    }
}

/// Small pill at the bottom-center of the screen with live waveform bars.
@MainActor
final class DictationHUD {
    private let panel: NSPanel
    static let size = CGSize(width: 180, height: 44)

    init(state: AppState) {
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = DebugFlags.capturable ? .readOnly : .none
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DictationHUDView(state: state))
    }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: vf.midX - Self.size.width / 2, y: vf.minY + 28))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.CA.fadeFast
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

import SwiftUI

private struct DictationHUDView: View {
    let state: AppState
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55, 0.9, 0.6]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.dictation == .processing ? "text.cursor" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: 3, height: barHeight(i))
                }
            }
            .animation(.easeOut(duration: 0.08), value: state.dictationLevel)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .frame(width: DictationHUD.size.width, height: DictationHUD.size.height)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state.dictation {
        case .handsFree: "hands-free"
        case .processing: "typing…"
        default: "dictating"
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        guard state.dictation != .processing else { return 4 }
        return 4 + CGFloat(state.dictationLevel) * 18 * weights[i]
    }
}
