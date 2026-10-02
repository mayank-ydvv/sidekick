import Foundation

enum ModelTier: String, Codable, CaseIterable, Identifiable {
    case auto, fast, smart
    var id: String { rawValue }
}

/// Picks Flash vs Pro for a talk request. Pure and cheap: O(length of text).
enum ModelRouter {
    static let smartPhrases = [
        "think hard", "think carefully", "think deeply", "think step by step",
        "explain in detail", "in detail", "in depth", "detailed explanation", "deep dive",
        "explain thoroughly", "walk me through the reasoning", "prove", "derive",
        "detail mein", "detail me", "achhe se samjhao", "acche se samjhao", "vistar se",
    ]
    static let longQuestionWords = 45

    static func route(_ text: String, mode: ModelTier) -> ModelTier {
        switch mode {
        case .fast, .smart: return mode
        case .auto:
            let t = text.lowercased()
            if smartPhrases.contains(where: { t.contains($0) }) { return .smart }
            let words = t.split(whereSeparator: { $0.isWhitespace }).count
            if words >= longQuestionWords { return .smart }
            return .fast
        }
    }
}
