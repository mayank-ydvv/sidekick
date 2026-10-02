import AppKit

enum LocalTools {
    static let all: [AgentTool] = [openApp, openURL, openPath]

    static let openApp = AgentTool(
        name: "open_app",
        description: "Open (or bring to front) a Mac app by name, e.g. \"Spotify\", \"Notes\".",
        parameters: Schema.object(["app": Schema.string("App name")], required: ["app"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard let name = args["app"] as? String else { return .error("missing app") }
            let ok = await MainActor.run { () -> Bool in
                let ws = NSWorkspace.shared
                if let url = resolveApp(name) {
                    ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return true
                }
                return false
            }
            return ok ? ToolResult(text: "opened \(name)") : .error("couldn't find an app called \(name) — it may not be installed")
        })

    static let openURL = AgentTool(
        name: "open_url",
        description: "Open a web URL (or a bare domain like github.com), or an app link like spotify:search:lofi, music://, maps://, slack://. Set app when the user names a browser or app (\"Google Chrome\", \"Firefox\", \"Arc\"); otherwise the default browser is used.",
        parameters: Schema.object(["url": Schema.string("URL or domain"),
                                   "app": Schema.string("Optional: browser/app to open it in, e.g. Google Chrome")], required: ["url"]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            guard let raw = args["url"] as? String, let url = normalizeURL(raw), allowedSchemes.contains(url.scheme?.lowercased() ?? "") else {
                return .error("that kind of link can't be opened")
            }
            // The user named a browser in the task but the model didn't pass it: still honour it for web links.
            let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            let appName = (args["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (isWeb ? ctx.preferredBrowser : nil)
            return await open([url], in: appName, what: url.absoluteString)
        })

    static let openPath = AgentTool(
        name: "open_path",
        description: "Open a folder (in Finder) or a document by path or by name, e.g. \"mac\", \"Downloads\", \"~/Desktop/notes.txt\". Finds it on the Desktop, in Documents, Downloads or home, then via Spotlight. Set app to open it with a specific app (e.g. open a folder in Visual Studio Code).",
        parameters: Schema.object(["path": Schema.string("A path, or just the file/folder name"),
                                   "app": Schema.string("Optional: app to open it with, e.g. Preview, Visual Studio Code")], required: ["path"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard let q = args["path"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return .error("missing path") }
            guard let url = locate(q) else { return .error("couldn't find a file or folder called \(q)") }
            // Never launch programs/installers this way: show them in Finder instead.
            if Self.runnableExtensions.contains(url.pathExtension.lowercased()) {
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                return ToolResult(text: "showed \(url.path) in Finder")
            }
            let app = (args["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return await open([url], in: app, what: url.path)
        })

    /// Opens URLs/files in a named app (or the default handler). Fails clearly if that app isn't installed.
    static func open(_ urls: [URL], in appName: String?, what: String) async -> ToolResult {
        guard let appName else {
            let ok = await MainActor.run { urls.allSatisfy { NSWorkspace.shared.open($0) } }
            return ok ? ToolResult(text: "opened \(what)") : .error("couldn't open \(what)")
        }
        guard let appURL = await MainActor.run(body: { resolveApp(appName) }) else {
            return .error("\(appName) isn't installed on this Mac — tell the user instead of opening it somewhere else")
        }
        do {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: cfg)
            return ToolResult(text: "opened \(what) in \(appURL.deletingPathExtension().lastPathComponent)")
        } catch {
            return .error("couldn't open \(what) in \(appName): \(error.localizedDescription)")
        }
    }

    /// "github.com" / "www.x.org/path" → https URL; full URLs and app links pass through.
    nonisolated static func normalizeURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>")))
        if let u = URL(string: s), let scheme = u.scheme, !scheme.isEmpty, s.contains(":"), !s.hasPrefix("localhost:") {
            // "github.com:443"-style host:port has no "//"; treat scheme-less domains below.
            if s.contains("://") || allowedSchemes.contains(scheme.lowercased()) { return u }
        }
        guard s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
                || s.hasPrefix("localhost") else { return nil }
        return URL(string: "https://" + s)
    }

    /// Common short names → the app's real name.
    nonisolated static let appAliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "google": "Google Chrome",
        "firefox": "Firefox", "mozilla": "Firefox", "edge": "Microsoft Edge", "microsoft edge": "Microsoft Edge",
        "brave": "Brave Browser", "arc": "Arc", "opera": "Opera", "safari": "Safari", "vivaldi": "Vivaldi",
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint", "outlook": "Microsoft Outlook",
        "teams": "Microsoft Teams", "terminal": "Terminal", "iterm": "iTerm", "settings": "System Settings",
        "system preferences": "System Settings", "app store": "App Store", "whatsapp": "WhatsApp", "facetime": "FaceTime",
        "music": "Music", "apple music": "Music", "photos": "Photos", "preview": "Preview", "notes": "Notes",
        "calendar": "Calendar", "mail": "Mail", "finder": "Finder", "xcode": "Xcode", "claude": "Claude", "netflix": "Netflix",
    ]

    /// Browsers named in a task ("open github on chrome") → that browser, so links never land in the default one.
    nonisolated static func browserMentioned(in text: String) -> String? {
        let t = " " + text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: " ") + " "
        let browsers: [(String, String)] = [("google chrome", "Google Chrome"), ("chrome", "Google Chrome"), ("firefox", "Firefox"),
                                            ("microsoft edge", "Microsoft Edge"), ("edge", "Microsoft Edge"), ("brave", "Brave Browser"),
                                            ("arc", "Arc"), ("opera", "Opera"), ("vivaldi", "Vivaldi"), ("safari", "Safari")]
        // Only when it's clearly the browser: "in/on/with/using/via <browser>", "<browser> browser", "open <browser>"
        // (so "search for edge cases" or "arc welding" don't count).
        for (key, app) in browsers {
            for lead in ["in", "on", "with", "using", "via", "through", "open", "launch"] {
                for mid in [" ", " the ", " google "] where t.contains(" \(lead)\(mid)\(key) ") { return app }
            }
            if t.contains(" \(key) browser ") || t.hasPrefix(" \(key) ") { return app }
        }
        return nil
    }

    static let runnableExtensions: Set<String> = ["app", "command", "sh", "zsh", "bash", "tool", "pkg", "mpkg", "dmg", "workflow", "scpt", "applescript", "terminal", "py", "rb", "pl", "jar"]

    /// Resolves a path or a bare name to an existing item. Exact (case-insensitive) name matches beat prefix matches;
    /// shallower locations win. Falls back to Spotlight under the home folder.
    nonisolated static func locate(_ query: String, roots: [URL]? = nil, spotlight: Bool = true) -> URL? {
        let fm = FileManager.default
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        if q.hasPrefix("~") { q = NSHomeDirectory() + q.dropFirst() }
        if q.hasPrefix("/"), fm.fileExists(atPath: q) { return URL(fileURLWithPath: q) }
        // "the mac folder" → "mac"
        var name = q.lowercased()
        for w in ["the ", "my "] where name.hasPrefix(w) { name.removeFirst(w.count) }
        for w in [" folder", " directory", " file"] where name.hasSuffix(w) { name.removeLast(w.count) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let bases = roots ?? ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) } + [home]
        var level = bases
        for _ in 0..<3 {
            var next: [URL] = []
            var prefixHit: URL?
            for dir in level {
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for item in items {
                    let n = item.lastPathComponent.lowercased()
                    let stem = item.deletingPathExtension().lastPathComponent.lowercased()
                    if n == name || stem == name { return item }
                    if prefixHit == nil, n.hasPrefix(name) { prefixHit = item }
                    if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, item.pathExtension.isEmpty,
                       !["library", "node_modules", ".git"].contains(n) { next.append(item) }
                }
            }
            if let p = prefixHit { return p }
            level = next
            if level.count > 400 { break }
        }
        guard spotlight else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), "kMDItemFSName == '\(name.replacingOccurrences(of: "'", with: ""))'c"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let paths = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.contains("/Library/") }
        return paths.min { $0.count < $1.count }.map { URL(fileURLWithPath: $0) }
    }

    /// Web + well-known app deep links. Never file:, javascript:, or settings panes.
    static let allowedSchemes: Set<String> = ["http", "https", "spotify", "music", "maps", "slack", "notion", "figma", "zoommtg", "msteams", "mailto"]

    @MainActor
    /// Bundle id, alias ("chrome"), exact name, or a name containing the words ("code" → Visual Studio Code),
    /// in the standard app folders; then Spotlight for apps installed elsewhere.
    static func resolveApp(_ raw: String) -> URL? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let ws = NSWorkspace.shared
        if name.contains("."), let u = ws.urlForApplication(withBundleIdentifier: name) { return u }
        let target = (appAliases[name.lowercased()] ?? name).lowercased().replacingOccurrences(of: ".app", with: "")
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        var candidates: [URL] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            candidates += items.filter { $0.hasSuffix(".app") }.map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        }
        func base(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent.lowercased() }
        if let hit = candidates.first(where: { base($0) == target })
            ?? candidates.first(where: { base($0).hasPrefix(target) })
            ?? candidates.first(where: { base($0).contains(target) }) { return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '*\(target.replacingOccurrences(of: "'", with: ""))*'cd"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let paths = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        return paths.map(String.init).filter { !$0.contains("/Library/") }.min { $0.count < $1.count }.map { URL(fileURLWithPath: $0) }
    }
}

enum ShellTool {
    /// Always requires confirmation; the exact command is shown to the user first.
    static let tool = AgentTool(
        name: "run_shell",
        description: "Run a zsh command on the user's Mac (30 s limit). The user must approve every command.",
        parameters: Schema.object(["command": Schema.string("The exact shell command")], required: ["command"]),
        requiresConfirmation: { _, _ in true },
        run: { args, ctx in
            guard let cmd = args["command"] as? String else { return .error("missing command") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.currentDirectoryURL = ctx.outputFolder
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let deadline = Date().addingTimeInterval(30)
            while p.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            if p.isRunning { p.terminate(); return .error("timed out after 30 s") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data.prefix(20_000), as: UTF8.self)
            return ToolResult(text: "exit \(p.terminationStatus)\n\(text)", isError: p.terminationStatus != 0)
        })
}
