import Foundation

enum FileTools {
    static let all: [AgentTool] = [list, read, write, createCSV, createMarkdown, createXLSX]

    /// Resolves a user/model path inside the allowed roots. Relative paths land in the output folder.
    /// Returns nil if the path escapes every allowed root (no `..` or symlink tricks).
    static func resolve(_ path: String, ctx: ToolContext) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : ctx.outputFolder.appendingPathComponent(expanded)
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        for root in [ctx.outputFolder] + ctx.allowedFolders {
            let r = root.standardizedFileURL.resolvingSymlinksInPath().path
            if target == r || target.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return URL(fileURLWithPath: target) }
        }
        return nil
    }

    static func safeName(_ s: String, ext: String) -> String {
        var n = s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "output" }
        if !n.lowercased().hasSuffix("." + ext) { n += "." + ext }
        return n
    }

    static let list = AgentTool(
        name: "files_list",
        description: "List files in the output folder or an approved folder.",
        parameters: Schema.object(["path": Schema.string("Folder path; empty = output folder")]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            let p = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ctx.outputFolder.path
            guard let dir = resolve(p, ctx: ctx) else { return .error("that folder isn't one i'm allowed to use") }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return ToolResult(text: items.sorted().prefix(200).joined(separator: "\n"))
        })

    static let read = AgentTool(
        name: "files_read",
        description: "Read a text file (first 100 KB) from the output folder or an approved folder.",
        parameters: Schema.object(["path": Schema.string("File path")], required: ["path"]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            guard let p = args["path"] as? String, let url = resolve(p, ctx: ctx) else { return .error("not allowed") }
            guard let data = try? Data(contentsOf: url) else { return .error("couldn't read \(p)") }
            return ToolResult(text: String(decoding: data.prefix(100_000), as: UTF8.self))
        })

    static let write = AgentTool(
        name: "files_write",
        description: "Write a text file in the output folder or an approved folder. Overwriting needs approval.",
        parameters: Schema.object(["path": Schema.string("File path or name"), "content": Schema.string("Text content")], required: ["path", "content"]),
        requiresConfirmation: { args, ctx in
            // Overwriting an existing file is destructive → ask.
            guard let p = args["path"] as? String, let url = resolve(p, ctx: ctx) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        },
        run: { args, ctx in
            guard let p = args["path"] as? String, let content = args["content"] as? String,
                  let url = resolve(p, ctx: ctx) else { return .error("not allowed") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(text: "saved \(url.lastPathComponent)", files: [url])
        })

    static let createCSV = AgentTool(
        name: "create_csv",
        description: "Create a CSV file in the output folder from a header row and data rows.",
        parameters: Schema.object([
            "filename": Schema.string("File name, e.g. top-companies.csv"),
            "header": Schema.array("Column names", items: ["type": "string"]),
            "rows": Schema.array("Rows; each row is an array of cell strings", items: ["type": "array", "items": ["type": "string"]]),
        ], required: ["filename", "header", "rows"]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            let (header, rows) = table(args)
            guard !header.isEmpty else { return .error("missing header") }
            let url = uniqueURL(ctx.outputFolder.appendingPathComponent(safeName(args["filename"] as? String ?? "table", ext: "csv")))
            try FileManager.default.createDirectory(at: ctx.outputFolder, withIntermediateDirectories: true)
            try csv(header: header, rows: rows).write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(text: "saved \(url.lastPathComponent) (\(rows.count) rows)", files: [url])
        })

    static let createMarkdown = AgentTool(
        name: "create_markdown",
        description: "Create a markdown document in the output folder.",
        parameters: Schema.object(["filename": Schema.string("File name"), "content": Schema.string("Markdown text")], required: ["filename", "content"]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            guard let content = args["content"] as? String else { return .error("missing content") }
            let url = uniqueURL(ctx.outputFolder.appendingPathComponent(safeName(args["filename"] as? String ?? "notes", ext: "md")))
            try FileManager.default.createDirectory(at: ctx.outputFolder, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(text: "saved \(url.lastPathComponent)", files: [url])
        })

    static let createXLSX = AgentTool(
        name: "create_xlsx",
        description: "Create an Excel .xlsx spreadsheet in the output folder from a header row and data rows.",
        parameters: Schema.object([
            "filename": Schema.string("File name"),
            "header": Schema.array("Column names", items: ["type": "string"]),
            "rows": Schema.array("Rows of cell strings", items: ["type": "array", "items": ["type": "string"]]),
        ], required: ["filename", "header", "rows"]),
        requiresConfirmation: { _, _ in false },
        run: { args, ctx in
            let (header, rows) = table(args)
            let url = uniqueURL(ctx.outputFolder.appendingPathComponent(safeName(args["filename"] as? String ?? "table", ext: "xlsx")))
            try FileManager.default.createDirectory(at: ctx.outputFolder, withIntermediateDirectories: true)
            try XLSXWriter.write(header: header, rows: rows, to: url)
            return ToolResult(text: "saved \(url.lastPathComponent) (\(rows.count) rows)", files: [url])
        })

    static func table(_ args: [String: Any]) -> ([String], [[String]]) {
        let header = (args["header"] as? [Any])?.map { "\($0)" } ?? []
        let rows = (args["rows"] as? [Any])?.compactMap { r -> [String]? in (r as? [Any])?.map { "\($0)" } } ?? []
        return (header, rows)
    }

    /// RFC 4180 CSV.
    static func csv(header: [String], rows: [[String]]) -> String {
        func cell(_ s: String) -> String {
            s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Never overwrite: "report.csv" → "report 2.csv".
    static func uniqueURL(_ url: URL) -> URL {
        var u = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: u.path) {
            u = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return u
    }
}

/// Minimal valid .xlsx (one sheet, inline strings, numbers as numbers), zipped with /usr/bin/zip.
enum XLSXWriter {
    static func write(header: [String], rows: [[String]], to url: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        for (path, content) in parts(header: header, rows: rows) {
            let f = tmp.appendingPathComponent(path)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: f, atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = tmp
        p.arguments = ["-q", "-X", "-r", url.path, "[Content_Types].xml", "_rels", "xl"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func parts(header: [String], rows: [[String]]) -> [(String, String)] {
        func col(_ i: Int) -> String {
            var n = i + 1, s = ""
            while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
            return s
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var sheet = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        for (r, row) in ([header] + rows).enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, v) in row.enumerated() {
                let ref = "\(col(c))\(r + 1)"
                let trimmed = v.replacingOccurrences(of: ",", with: "")
                if r > 0, Double(trimmed) != nil, !v.isEmpty {
                    sheet += "<c r=\"\(ref)\"><v>\(trimmed)</v></c>"
                } else {
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(esc(v))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        return [
            ("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#),
            ("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#),
            ("xl/workbook.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#),
            ("xl/_rels/workbook.xml.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
    }
}
