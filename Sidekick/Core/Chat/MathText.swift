import Foundation

/// Turns LaTeX math the model sometimes writes ($…$, $$…$$, \times, \frac{a}{b}, x^2) into plain,
/// readable text (×, a/b, x²) so answers never show raw dollar signs and backslashes.
/// Currency like "$3000" is left alone; code blocks are untouched.
enum MathText {
    static func clean(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\") else { return text }
        var out: [String] = []
        var inCode = false
        var display: [String]? = nil   // collecting a multi-line $$ … $$ block
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); out.append(line); continue }
            if inCode { out.append(line); continue }
            if display != nil {
                if trimmed.hasSuffix("$$") || trimmed == "\\]" {
                    display!.append(String(trimmed.dropLast(trimmed == "\\]" ? 2 : 2)))
                    out.append("**" + latex(display!.joined(separator: " ")).trimmingCharacters(in: .whitespaces) + "**")
                    display = nil
                } else {
                    display!.append(trimmed)
                }
                continue
            }
            if trimmed == "$$" || trimmed == "\\[" { display = []; continue }
            out.append(cleanLine(line))
        }
        if let d = display { out.append(latex(d.joined(separator: " "))) }
        return out.joined(separator: "\n")
    }

    /// LaTeX commands that mark a backslash as math (anything else — "\n", "C:\Users" — is left alone).
    static let latexCommand = #"\\(frac|dfrac|tfrac|sqrt|times|cdot|div|pm|mp|le|leq|ge|geq|neq|ne|approx|equiv|infty|degree|circ|rightarrow|to|leftarrow|Rightarrow|implies|iff|therefore|because|sum|prod|int|partial|alpha|beta|gamma|delta|Delta|theta|lambda|mu|pi|sigma|Sigma|phi|omega|Omega|epsilon|rho|tau|text|textbf|mathrm|mathbf|mathit|operatorname|boxed|left|right|quad|qquad)\b"#

    private static func cleanLine(_ line: String) -> String {
        // Inline `code` spans are never touched.
        let parts = line.components(separatedBy: "`")
        guard parts.count > 2 else { return cleanProse(line) }
        return parts.enumerated().map { i, p in i % 2 == 1 ? p : cleanProse(p) }.joined(separator: "`")
    }

    private static func cleanProse(_ line: String) -> String {
        var s = line
        // Display math on one line: $$…$$ or \[…\] → bold, so the key equation stands out.
        s = replace(s, #"\$\$(.+?)\$\$"#) { "**" + latex($0).trimmingCharacters(in: .whitespaces) + "**" }
        s = replace(s, #"\\\[(.+?)\\\]"#) { "**" + latex($0).trimmingCharacters(in: .whitespaces) + "**" }
        s = replace(s, #"\\\((.+?)\\\)"#) { latex($0) }
        // Inline $…$ only when it looks like math (not two prices like "$5 and $10").
        s = replace(s, #"\$([^$\n]+?)\$"#) { inner in
            looksLikeMath(inner) ? latex(inner) : "$" + inner + "$"
        }
        // Bare LaTeX outside delimiters (e.g. "3 \times 4") — only for real LaTeX commands.
        if s.range(of: latexCommand, options: .regularExpression) != nil { s = latex(s) }
        return s
    }

    static func looksLikeMath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t.contains("\\") || t.contains("^") || t.contains("_") || t.contains("=") || t.contains("{") { return true }
        // A lone variable or tiny expression: $P$, $r$, $5$, $x+1$.
        if t.count <= 6, !t.contains(" ") { return true }
        let hasOperator = t.contains(where: { "+-*/=<>×÷".contains($0) })
        let words = t.split(whereSeparator: { !$0.isLetter }).filter { $0.count > 1 }
        return hasOperator && words.isEmpty
    }

    // MARK: LaTeX → Unicode

    static let symbols: [(String, String)] = [
        ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
        ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"), ("\\neq", "≠"), ("\\ne", "≠"),
        ("\\approx", "≈"), ("\\equiv", "≡"), ("\\propto", "∝"), ("\\infty", "∞"), ("\\degree", "°"), ("^\\circ", "°"),
        ("\\rightarrow", "→"), ("\\to", "→"), ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"), ("\\implies", "⇒"), ("\\iff", "⇔"),
        ("\\therefore", "∴"), ("\\because", "∵"), ("\\sum", "Σ"), ("\\prod", "Π"), ("\\int", "∫"), ("\\partial", "∂"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"), ("\\Delta", "Δ"), ("\\theta", "θ"),
        ("\\lambda", "λ"), ("\\mu", "μ"), ("\\pi", "π"), ("\\sigma", "σ"), ("\\Sigma", "Σ"), ("\\phi", "φ"), ("\\omega", "ω"),
        ("\\Omega", "Ω"), ("\\epsilon", "ε"), ("\\rho", "ρ"), ("\\tau", "τ"),
        ("\\%", "%"), ("\\$", "$"), ("\\&", "&"), ("\\#", "#"), ("\\_", "_"),
        ("\\left", ""), ("\\right", ""), ("\\displaystyle", ""), ("\\quad", "  "), ("\\qquad", "   "),
        ("\\,", " "), ("\\;", " "), ("\\:", " "), ("\\!", ""), ("\\ ", " "), ("\\\\", " "),
    ]

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "n": "ⁿ", "x": "ˣ", "(": "⁽", ")": "⁾",
    ]

    static func latex(_ input: String) -> String {
        var s = input
        // Text-like wrappers: \text{abc} → abc
        for cmd in ["text", "textbf", "mathrm", "mathbf", "mathit", "operatorname", "boxed", "mbox"] {
            s = replace(s, "\\\\" + cmd + #"\{([^{}]*)\}"#) { $0 }
        }
        // \frac{a}{b} → a/b (parenthesized when needed); repeat for nesting.
        for _ in 0..<3 {
            s = replace(s, #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, groups: 2) { g in
                wrap(g[0]) + "/" + wrap(g[1])
            }
        }
        s = replace(s, #"\\sqrt\{([^{}]*)\}"#) { "√" + wrap($0) }
        for (k, v) in symbols { s = s.replacingOccurrences(of: k, with: v) }
        // Powers: x^{2} / x^2 → x²
        s = replace(s, #"\^\{([^{}]*)\}"#) { sup($0) }
        s = replace(s, #"\^([0-9n+\-x])"#) { sup($0) }
        // Subscripts: x_{1} / x_1 → x₁ (digits) or x_1 kept readable as x1
        s = replace(s, #"_\{([^{}]*)\}"#) { sub($0) }
        s = replace(s, #"_([0-9])"#) { sub($0) }
        // Any other \command → its name; drop leftover braces.
        s = replace(s, #"\\([a-zA-Z]+)"#) { $0 }
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s.replacingOccurrences(of: "  ", with: " ")
    }

    private static func wrap(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count > 1 && t.contains(where: { "+-×·÷ ".contains($0) }) ? "(" + t + ")" : t
    }

    private static func sup(_ s: String) -> String {
        let mapped = s.compactMap { superscripts[$0] }
        return mapped.count == s.count ? String(mapped) : "^(" + s + ")"
    }

    private static func sub(_ s: String) -> String {
        let table: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉"]
        let mapped = s.compactMap { table[$0] }
        return mapped.count == s.count ? String(mapped) : s
    }

    private static func replace(_ s: String, _ pattern: String, groups: Int = 1, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let gs = (1...groups).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            result += f(gs)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func replace(_ s: String, _ pattern: String, _ f: (String) -> String) -> String {
        replace(s, pattern, groups: 1) { f($0[0]) }
    }
}
