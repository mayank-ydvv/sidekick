import AVFoundation
import NaturalLanguage

/// Picks a speaking voice that matches the reply's language. Pure (voices injected) so it's unit-tested.
enum VoiceSelector {
    struct Voice: Equatable {
        var id: String
        var language: String      // BCP-47, e.g. "en-US", "hi-IN"
        var quality: Int          // higher = better (premium > enhanced > default)
        var female = false
        var name = ""
    }

    /// Soft, natural-sounding female voices, best first (premium/enhanced versions win on quality).
    static let softFemale = ["Ava", "Zoe", "Allison", "Susan", "Serena", "Samantha", "Tara", "Moira", "Karen", "Tessa", "Lekha"]
    static func softRank(_ v: Voice) -> Int { softFemale.firstIndex(of: v.name) ?? softFemale.count }

    /// Romanized Hindi words that strongly signal Hinglish in Latin script.
    static let hinglishMarkers: Set<String> = [
        "hai", "hain", "nahi", "nahin", "kya", "aur", "mein", "main", "ki", "ka", "ke", "ko", "ho", "raha", "rahi", "kar",
        "karo", "toh", "bhi", "ye", "yeh", "woh", "aap", "hum", "tum", "kaise", "kyun", "abhi", "thoda", "accha", "theek",
    ]

    /// Language code for the text: "hi" (Devanagari), "hinglish", or an NL language code like "en", "fr".
    static func language(of text: String) -> String {
        if text.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) { return "hi" }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let hits = words.filter { hinglishMarkers.contains($0) }.count
        if hits >= 2, Double(hits) / Double(max(words.count, 1)) >= 0.12 { return "hinglish" }
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue ?? "en"
    }

    /// Keeps the user's chosen voice if it fits the language; otherwise the best installed voice for it.
    static func pick(for text: String, preferred: String?, voices: [Voice]) -> String? {
        let lang = language(of: text)
        let wanted: (Voice) -> Bool = { v in
            switch lang {
            case "hi": v.language.hasPrefix("hi")
            case "hinglish": v.language == "en-IN" || v.language.hasPrefix("hi")
            default: v.language.lowercased().hasPrefix(lang.lowercased())
            }
        }
        if let p = preferred, let v = voices.first(where: { $0.id == p }), wanted(v) { return p }
        let candidates = voices.filter(wanted).sorted {
            // Hinglish: Indian English first (reads romanized Hindi well), then Hindi.
            let a = lang == "hinglish" && $0.language == "en-IN", b = lang == "hinglish" && $1.language == "en-IN"
            if a != b { return a }
            // A female voice always beats a male one; then quality; then the softest-sounding name.
            if $0.female != $1.female { return $0.female }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return softRank($0) < softRank($1)
        }
        return candidates.first?.id ?? preferred
    }

    static func installed() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices().map { Voice(id: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                                             female: $0.gender == .female, name: $0.name) }
    }
}
