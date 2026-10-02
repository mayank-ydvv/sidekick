import Foundation
import Observation

/// All user-tunable settings, persisted as one JSON blob in UserDefaults.
struct SettingsData: Codable, Equatable {
    // AI
    var fastModel = "gemini-3.8-flash"
    var smartModel = "gemini-3.1-pro-preview"
    var cheapModel = "gemini-3.5-flash-lite"
    var thinkingLevel = "low"              // minimal | low | medium | high | off (gemini-3.8-flash rejects minimal)
    var smartThinkingLevel = "low"
    var modelTier: ModelTier = .auto
    var prices: [String: ModelPrice] = [
        "gemini-3.8-flash": ModelPrice(inputPerMillion: 0.5, outputPerMillion: 3.0),
        "gemini-3.1-pro-preview": ModelPrice(inputPerMillion: 2.0, outputPerMillion: 12.0),
        "gemini-3.5-flash-lite": ModelPrice(inputPerMillion: 0.1, outputPerMillion: 0.4),
    ]
    var dailyBudgetUSD = 1.0
    var hardStopAtBudget = true
    // Voice
    var whisperModel: WhisperModel = .small
    var language = ""                       // "" = auto-detect
    var ttsVoiceID: String? = nil
    var ttsRate: Float = 0.48
    var ttsPitch: Float = 1.0
    var ttsVolume: Float = 1.0
    var textOnly = false
    /// Offline natural voice (Kokoro / Piper) instead of the Mac's built-in voices, when installed.
    var naturalVoice = true
    var naturalVoiceName = NeuralTTS.defaultVoice
    // Shortcuts
    var pushToTalk: ModifierSet = [.control, .option]
    var dictateKeys: ModifierSet = [.fn, .control]
    var alwaysOnKey: ModifierSet = [.control]
    var homeChord: KeyChord = .home
    var polishDictation = false
    // Buddy
    var showBuddy = true
    /// The text bubble next to the cursor (status otherwise lives in the notch).
    var showCursorBubble = false
    var dockBuddy = false
    // General
    var launchAtLogin = false
    var peekOnHover = true
    var proactiveSuggestions = false
    var afternoonSuggestions = false
    var quietMode = true
    // Agents
    var agentFolders: [String] = []
    /// Tasks run without asking (computer use, overwrites, connector actions, shell). Risky shell commands still ask.
    var autoApprove = true
    // Privacy
    var readBrowserURL = true
    var onboardingDone = false
}


extension SettingsData {
    /// Tolerant decoding: missing keys keep their defaults, so adding settings never wipes saved ones.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(type(of: fastModel), forKey: .fastModel) { fastModel = v }
        if let v = try? c.decodeIfPresent(type(of: smartModel), forKey: .smartModel) { smartModel = v }
        if let v = try? c.decodeIfPresent(type(of: cheapModel), forKey: .cheapModel) { cheapModel = v }
        if let v = try? c.decodeIfPresent(type(of: thinkingLevel), forKey: .thinkingLevel) { thinkingLevel = v }
        if let v = try? c.decodeIfPresent(type(of: smartThinkingLevel), forKey: .smartThinkingLevel) { smartThinkingLevel = v }
        if let v = try? c.decodeIfPresent(type(of: modelTier), forKey: .modelTier) { modelTier = v }
        if let v = try? c.decodeIfPresent(type(of: prices), forKey: .prices) { prices = v }
        if let v = try? c.decodeIfPresent(type(of: dailyBudgetUSD), forKey: .dailyBudgetUSD) { dailyBudgetUSD = v }
        if let v = try? c.decodeIfPresent(type(of: hardStopAtBudget), forKey: .hardStopAtBudget) { hardStopAtBudget = v }
        if let v = try? c.decodeIfPresent(type(of: whisperModel), forKey: .whisperModel) { whisperModel = v }
        if let v = try? c.decodeIfPresent(type(of: language), forKey: .language) { language = v }
        if let v = try? c.decodeIfPresent(type(of: ttsVoiceID), forKey: .ttsVoiceID) { ttsVoiceID = v }
        if let v = try? c.decodeIfPresent(type(of: ttsRate), forKey: .ttsRate) { ttsRate = v }
        if let v = try? c.decodeIfPresent(type(of: ttsPitch), forKey: .ttsPitch) { ttsPitch = v }
        if let v = try? c.decodeIfPresent(type(of: ttsVolume), forKey: .ttsVolume) { ttsVolume = v }
        if let v = try? c.decodeIfPresent(type(of: naturalVoice), forKey: .naturalVoice) { naturalVoice = v }
        if let v = try? c.decodeIfPresent(type(of: naturalVoiceName), forKey: .naturalVoiceName) { naturalVoiceName = v }
        if let v = try? c.decodeIfPresent(type(of: textOnly), forKey: .textOnly) { textOnly = v }
        if let v = try? c.decodeIfPresent(type(of: pushToTalk), forKey: .pushToTalk) { pushToTalk = v }
        if let v = try? c.decodeIfPresent(type(of: dictateKeys), forKey: .dictateKeys) { dictateKeys = v }
        if let v = try? c.decodeIfPresent(type(of: alwaysOnKey), forKey: .alwaysOnKey) { alwaysOnKey = v }
        if let v = try? c.decodeIfPresent(type(of: homeChord), forKey: .homeChord) { homeChord = v }
        if let v = try? c.decodeIfPresent(type(of: polishDictation), forKey: .polishDictation) { polishDictation = v }
        if let v = try? c.decodeIfPresent(type(of: showBuddy), forKey: .showBuddy) { showBuddy = v }
        if let v = try? c.decodeIfPresent(type(of: showCursorBubble), forKey: .showCursorBubble) { showCursorBubble = v }
        if let v = try? c.decodeIfPresent(type(of: dockBuddy), forKey: .dockBuddy) { dockBuddy = v }
        if let v = try? c.decodeIfPresent(type(of: readBrowserURL), forKey: .readBrowserURL) { readBrowserURL = v }
        if let v = try? c.decodeIfPresent(type(of: agentFolders), forKey: .agentFolders) { agentFolders = v }
        if let v = try? c.decodeIfPresent(type(of: launchAtLogin), forKey: .launchAtLogin) { launchAtLogin = v }
        if let v = try? c.decodeIfPresent(type(of: peekOnHover), forKey: .peekOnHover) { peekOnHover = v }
        if let v = try? c.decodeIfPresent(type(of: proactiveSuggestions), forKey: .proactiveSuggestions) { proactiveSuggestions = v }
        if let v = try? c.decodeIfPresent(type(of: afternoonSuggestions), forKey: .afternoonSuggestions) { afternoonSuggestions = v }
        if let v = try? c.decodeIfPresent(type(of: quietMode), forKey: .quietMode) { quietMode = v }
        if let v = try? c.decodeIfPresent(type(of: onboardingDone), forKey: .onboardingDone) { onboardingDone = v }
        if let v = try? c.decodeIfPresent(type(of: autoApprove), forKey: .autoApprove) { autoApprove = v }
    }
}

@MainActor
@Observable
final class AppSettings {
    private static let key = "settings.v1"
    var data: SettingsData {
        didSet { if data != oldValue { save() } }
    }

    init() {
        if let raw = UserDefaults.standard.data(forKey: Self.key),
           let d = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = d
        } else {
            data = SettingsData()
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }
}

/// Persists the CostMeter in UserDefaults (moves to GRDB `usage_daily` in Phase 5).
@MainActor
@Observable
final class UsageStore {
    private static let key = "usage.v1"
    private(set) var meter: CostMeter
    /// Daily rows for the Usage chart (spec table `usage_daily`).
    var db: AppDatabase?

    init(prices: [String: ModelPrice], budget: Double) {
        if let raw = UserDefaults.standard.data(forKey: Self.key),
           var m = try? JSONDecoder().decode(CostMeter.self, from: raw) {
            m.prices = prices
            m.dailyBudgetUSD = budget
            meter = m
        } else {
            meter = CostMeter(prices: prices, dailyBudgetUSD: budget)
        }
    }

    func configure(prices: [String: ModelPrice], budget: Double) {
        meter.prices = prices
        meter.dailyBudgetUSD = budget
    }

    @discardableResult
    func record(model: String, usage: TokenUsage) -> Double {
        let c = meter.record(model: model, usage: usage)
        if let raw = try? JSONEncoder().encode(meter) { UserDefaults.standard.set(raw, forKey: Self.key) }
        if let db {
            let day = CostMeter.dayKey(Date())
            Task.detached { try? await db.recordUsage(date: day, model: model, usage: usage, cost: c) }
        }
        return c
    }
}
