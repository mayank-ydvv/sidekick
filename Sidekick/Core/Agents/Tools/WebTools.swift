import Foundation

enum WebTools {
    static let all: [AgentTool] = [search, fetch]

    /// Google Search grounding through Gemini (a separate call: grounding can't be mixed with function tools).
    static let search = AgentTool(
        name: "web_search",
        description: "Search the web for current facts. Returns a summary with source links.",
        parameters: Schema.object(["query": Schema.string("What to search for")], required: ["query"]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            guard let q = args["query"] as? String else { return .error("missing query") }
            let body: [String: Any] = [
                "contents": [["role": "user", "parts": [["text": "Search the web and answer factually with specific numbers and dates. Query: \(q)"]]]],
                "tools": [["google_search": [String: Any]()]],
            ]
            let payload = try JSONSerialization.data(withJSONObject: body)
            var lastError: Error?
            for model in [ctx.searchModel, ctx.fallbackModel].compactMap({ $0 }) {
                // Search grounding has its own quota, so it is tracked separately from normal replies.
                if await MainActor.run(body: { ModelHealth.isBlocked("search:" + model) }) { continue }
                do {
                    let data = try await ctx.gemini.generateRaw(model: model, body: payload)
                    return ToolResult(text: parseGrounded(data))
                } catch let e as GeminiError where TalkCoordinator.shouldFallBack(e) {
                    lastError = e   // limited / overloaded → try the next model
                    await MainActor.run { ModelHealth.block("search:" + model, for: e) }
                }
            }
            // Gemini search quota used up (common on free keys): plain DuckDuckGo results instead.
            if let results = try? await duckDuckGo(q), !results.isEmpty {
                return ToolResult(text: "Web results (open the most relevant with fetch_url for details):\n" + results)
            }
            throw lastError ?? GeminiError.badResponse
        })

    /// Keyless fallback search: DuckDuckGo's HTML endpoint → "- title: url — snippet" lines.
    static func duckDuckGo(_ query: String) async throws -> String {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return parseDuckDuckGo(String(decoding: data, as: UTF8.self))
    }

    static func parseDuckDuckGo(_ html: String, limit: Int = 8) -> String {
        guard let link = try? NSRegularExpression(pattern: #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators]),
              let snip = try? NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators]) else { return "" }
        let ns = html as NSString
        let all = NSRange(location: 0, length: ns.length)
        let links = link.matches(in: html, range: all)
        let snips = snip.matches(in: html, range: all)
        var out: [String] = []
        for (i, m) in links.prefix(limit).enumerated() {
            var url = ns.substring(with: m.range(at: 1))
            // Redirect links: //duckduckgo.com/l/?uddg=<encoded url>
            if let r = url.range(of: "uddg="), let enc = url[r.upperBound...].split(separator: "&").first,
               let dec = String(enc).removingPercentEncoding { url = dec }
            if url.hasPrefix("//") { url = "https:" + url }
            let title = htmlToText(ns.substring(with: m.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = i < snips.count ? htmlToText(ns.substring(with: snips[i].range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard url.hasPrefix("http"), !url.contains("duckduckgo.com/y.js") else { continue }
            out.append("- \(title.isEmpty ? url : title): \(url)" + (snippet.isEmpty ? "" : " — \(snippet)"))
        }
        return out.joined(separator: "\n")
    }

    static func parseGrounded(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cand = (json["candidates"] as? [[String: Any]])?.first else { return "no results" }
        let parts = ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var text = parts.compactMap { $0["text"] as? String }.joined()
        let chunks = ((cand["groundingMetadata"] as? [String: Any])?["groundingChunks"] as? [[String: Any]]) ?? []
        let sources = chunks.compactMap { c -> String? in
            guard let w = c["web"] as? [String: Any], let uri = w["uri"] as? String else { return nil }
            return "- \(w["title"] as? String ?? "source"): \(uri)"
        }
        if !sources.isEmpty { text += "\n\nSources:\n" + sources.prefix(8).joined(separator: "\n") }
        return text.isEmpty ? "no results" : text
    }

    static let fetch = AgentTool(
        name: "fetch_url",
        description: "Fetch a web page and return its readable text (first 30 KB).",
        parameters: Schema.object(["url": Schema.string("http(s) URL")], required: ["url"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard let s = args["url"] as? String, let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return .error("invalid url")
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.setValue("Mozilla/5.0 (Macintosh) Sidekick", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let mime = (resp as? HTTPURLResponse)?.mimeType ?? ""
            let raw = String(decoding: data.prefix(2_000_000), as: UTF8.self)
            let text = mime.contains("html") || raw.contains("<html") ? htmlToText(raw) : raw
            return ToolResult(text: String(text.prefix(30_000)))
        })

    /// Readable text from HTML: drops script/style/nav/etc, keeps block breaks, decodes common entities. O(n).
    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n[ \\n]*", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
