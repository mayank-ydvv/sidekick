import Foundation

/// "Sidekick knows its own settings": a compact map for the talk prompt, and a safe way to apply
/// a spoken change ("talk slower") after the user confirms.
enum SettingsMap {
    struct Change: Equatable {
        var key: String
        var value: String
        var description: String
    }

    static let promptBlock = """
    Settings you can change for the user (always with their confirmation) by emitting [SETTING key=".." value=".."]:
    voice_speed: slower | faster | normal · voice: on | off (text only) · buddy: show | hide | dock | follow ·
    model: auto | fast | smart · language: auto | en | hi | <code> · speech_model: base | small | large ·
    dictation_polish: on | off · suggestions: on | off · quiet_mode: on | off
    """

    /// Validates and describes a change without applying it.
    static func prepare(key rawKey: String, value rawValue: String, current: SettingsData) -> Change? {
        let key = rawKey.lowercased(), value = rawValue.lowercased().trimmingCharacters(in: .whitespaces)
        switch key {
        case "voice_speed":
            guard ["slower", "faster", "normal"].contains(value) || Float(value) != nil else { return nil }
            let target = rate(value, current: current.ttsRate)
            return Change(key: key, value: String(target), description: "talk \(value == "normal" ? "at normal speed" : value)")
        case "voice":
            guard ["on", "off"].contains(value) else { return nil }
            return Change(key: key, value: value, description: value == "off" ? "show text only, no voice" : "turn my voice back on")
        case "buddy":
            guard ["show", "hide", "dock", "follow"].contains(value) else { return nil }
            return Change(key: key, value: value, description: [
                "show": "show the buddy", "hide": "hide the buddy", "dock": "dock the buddy in the notch", "follow": "have the buddy follow your cursor",
            ][value]!)
        case "model":
            guard ModelTier(rawValue: value) != nil else { return nil }
            return Change(key: key, value: value, description: "use the \(value) model")
        case "language":
            guard value == "auto" || (2...3).contains(value.count) else { return nil }
            return Change(key: key, value: value, description: value == "auto" ? "detect your language automatically" : "always listen for language \"\(value)\"")
        case "speech_model":
            guard ["base", "small", "large"].contains(value) else { return nil }
            return Change(key: key, value: value, description: "switch my ears to the \(value) speech model")
        case "dictation_polish", "suggestions", "quiet_mode":
            guard ["on", "off"].contains(value) else { return nil }
            let what = ["dictation_polish": "ai polish for dictation", "suggestions": "morning suggestions", "quiet_mode": "quiet mode"][key]!
            return Change(key: key, value: value, description: "turn \(value) \(what)")
        default:
            return nil
        }
    }

    static func rate(_ v: String, current: Float) -> Float {
        switch v {
        case "slower": return max(0.35, current - 0.06)
        case "faster": return min(0.65, current + 0.06)
        case "normal": return 0.52
        default: return min(0.65, max(0.35, Float(v) ?? current))
        }
    }

    static func apply(_ c: Change, to d: inout SettingsData) {
        switch c.key {
        case "voice_speed": d.ttsRate = Float(c.value) ?? d.ttsRate
        case "voice": d.textOnly = c.value == "off"
        case "buddy":
            switch c.value {
            case "show": d.showBuddy = true
            case "hide": d.showBuddy = false
            case "dock": d.dockBuddy = true
            default: d.dockBuddy = false
            }
        case "model": d.modelTier = ModelTier(rawValue: c.value) ?? d.modelTier
        case "language": d.language = c.value == "auto" ? "" : c.value
        case "speech_model": d.whisperModel = ["base": .base, "small": .small, "large": .largeTurbo][c.value] ?? d.whisperModel
        case "dictation_polish": d.polishDictation = c.value == "on"
        case "suggestions": d.proactiveSuggestions = c.value == "on"
        case "quiet_mode": d.quietMode = c.value == "on"
        default: break
        }
    }

    static func isYes(_ t: String) -> Bool { YesNo.answer(t) == true }
    static func isNo(_ t: String) -> Bool { YesNo.answer(t) == false }
}

/// Short spoken answers ("yeah sure", "haan", "nope, not now") → yes / no / nil. Whole words and phrases only,
/// so "now", "know" or "book" never count; the first answer word wins ("no, wait… yes" is no).
enum YesNo {
    static let yesPhrases = ["go ahead", "do it", "go for it", "sounds good", "why not", "of course", "please do", "kar do",
                             "theek hai", "thik hai", "tick hai", "haan ji", "ha ji", "let's do it", "lets do it", "that's fine"]
    static let noPhrases = ["not now", "never mind", "nevermind", "leave it", "rehne do", "don't", "do not", "no thanks", "mat karo"]
    static let yesWords: Set<String> = ["yes", "yeah", "yea", "yep", "yup", "ya", "yah", "sure", "ok", "okay", "okey", "alright",
                                        "allow", "approve", "correct", "absolutely", "definitely", "please", "haan", "han", "ha",
                                        "haa", "hanji", "theek", "thik", "accha", "achha"]
    static let noWords: Set<String> = ["no", "nope", "nah", "cancel", "stop", "deny", "nahi", "nahin", "na", "mat", "dont"]

    static func answer(_ text: String) -> Bool? {
        let t = " " + text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }.joined(separator: " ") + " "
        // Devanagari: हाँ / हां / जी / ठीक → yes, नहीं / ना / मत → no.
        if ["नहीं", "नही", " ना ", "मत"].contains(where: text.contains) { return false }
        if ["हाँ", "हां", "ठीक", "जी"].contains(where: text.contains) { return true }
        var firstYes = Int.max, firstNo = Int.max
        func note(_ phrase: String, yes: Bool) {
            if let r = t.range(of: " " + phrase + " ") {
                let i = t.distance(from: t.startIndex, to: r.lowerBound)
                if yes { firstYes = min(firstYes, i) } else { firstNo = min(firstNo, i) }
            }
        }
        noPhrases.forEach { note($0, yes: false) }
        yesPhrases.forEach { note($0, yes: true) }
        noWords.forEach { note($0, yes: false) }
        yesWords.forEach { note($0, yes: true) }
        if firstYes == Int.max, firstNo == Int.max { return nil }
        return firstYes < firstNo
    }
}

/// One friendly sentence for any error.
enum Friendly {
    static func message(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "looks like you're offline — try again when you're back online"
            case .timedOut: return "that took too long — try again?"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "i can't reach gemini right now — check your connection"
            default: return "network hiccup — try again?"
            }
        }
        if error is TimeoutError { return "that took too long — try again?" }
        let text = error.localizedDescription
        return text.isEmpty ? "something went wrong — try again?" : text
    }
}
