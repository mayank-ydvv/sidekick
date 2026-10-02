import SwiftUI
import UniformTypeIdentifiers

struct BuddiesTab: View {
    let env: AppEnvironment
    @State private var newName = ""
    @State private var newRole = ""
    @State private var routineFor: BuddyRecord?
    @State private var routinePrompt = ""
    @State private var routineSchedule = "daily 21:00"
    @State private var error: String?

    var body: some View {
        Form {
            Section("new buddy") {
                TextField("name (2 friendly words)", text: $newName)
                TextField("what it does", text: $newRole)
                Button("create") {
                    Task {
                        _ = try? await env.buddies.create(name: newName, role: newRole)
                        newName = ""; newRole = ""
                    }
                }.disabled(newName.isEmpty || newRole.isEmpty)
                Text("or just ask: \"make me a buddy that summarizes my day every evening at 9\"").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(env.buddies.buddies) { b in
                Section {
                    HStack {
                        BuddyAvatarView(preset: b.avatar, size: 22)
                        VStack(alignment: .leading) {
                            Text(b.name).fontWeight(.semibold)
                            Text(b.rolePrompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("folder") { NSWorkspace.shared.open(URL(fileURLWithPath: b.folderPath)) }
                        Button(b.archived ? "unarchive" : "archive") { env.buddies.setArchived(b, !b.archived) }
                    }
                    ForEach(env.buddies.routines(for: b)) { r in
                        HStack {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(r.prompt).lineLimit(1)
                                Text((Schedule.parse(r.schedule)?.label ?? r.schedule)
                                     + (r.nextRunAt.map { " · next \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                                     + (r.failCount > 0 ? " · \(r.failCount) failed" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { r.enabled }, set: { v in
                                var u = r; u.enabled = v; u.failCount = v ? 0 : u.failCount
                                Task { await env.buddies.saveRoutine(u); env.scheduler.reschedule() }
                            })).labelsHidden().accessibilityLabel("routine enabled")
                            Button("run now") { env.scheduler.runNow(r) }
                            Button { env.buddies.deleteRoutine(r); env.scheduler.reschedule() } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("delete routine")
                        }
                    }
                    Button("add routine…") { routineFor = b }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $routineFor) { b in
            VStack(alignment: .leading, spacing: 10) {
                Text("new routine for \(b.name)").font(.headline)
                TextField("what to do", text: $routinePrompt)
                TextField("when (daily 21:00, weekdays 9am, weekly mon 08:00, every 3 hours)", text: $routineSchedule)
                Text(Schedule.parse(routineSchedule)?.label ?? "i don't understand that schedule yet").font(.caption)
                    .foregroundStyle(Schedule.parse(routineSchedule) == nil ? .orange : .secondary)
                if let error { Text(error).foregroundStyle(.orange).font(.caption) }
                HStack {
                    Button("cancel") { routineFor = nil }
                    Spacer()
                    Button("save") {
                        Task {
                            do {
                                _ = try await env.buddies.addRoutine(buddy: b, prompt: routinePrompt, schedule: routineSchedule)
                                env.scheduler.reschedule()
                                routineFor = nil; routinePrompt = ""
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(routinePrompt.isEmpty || Schedule.parse(routineSchedule) == nil).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 420)
        }
    }
}

struct SkillsTab: View {
    let env: AppEnvironment
    @State private var editing: Skill?
    @State private var creating = false
    @State private var idea = ""
    @State private var drafting = false
    @State private var draftError: String?
    @State private var name = ""
    @State private var desc = ""
    @State private var triggers = ""
    @State private var skillBody = ""

    var body: some View {
        Form {
            Section {
                Text("skills are markdown instructions added to my prompts. enabled skills with triggers only apply when your message mentions one.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("create a skill…") { creating = true; name = ""; desc = ""; triggers = ""; skillBody = ""; idea = "" }
                    Button("import .md…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                        if p.runModal() == .OK, let u = p.url { env.skills.importFile(u) }
                    }
                    Button("show folder") { NSWorkspace.shared.open(env.skills.directory) }
                }
            }
            Section("library") {
                ForEach(env.skills.skills) { s in
                    HStack {
                        Toggle(isOn: Binding(get: { env.skills.enabled.contains(s.id) }, set: { _ in env.skills.toggle(s) })) {
                            VStack(alignment: .leading) {
                                Text(s.name)
                                Text(s.description + (s.triggers.isEmpty ? " · always" : " · when: " + s.triggers.joined(separator: ", ")))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("edit") { editing = s; name = s.name; desc = s.description; triggers = s.triggers.joined(separator: ", "); skillBody = s.body }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([s.file]) } label: { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless).accessibilityLabel("export \(s.name)")
                        Button { env.skills.delete(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("delete \(s.name)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { creating || editing != nil }, set: { if !$0 { creating = false; editing = nil } })) {
            VStack(alignment: .leading, spacing: 8) {
                Text(editing == nil ? "create a skill" : "edit skill").font(.headline)
                if editing == nil {
                    HStack {
                        TextField("describe it (e.g. \"answer like a senior iOS engineer\")", text: $idea)
                        Button(drafting ? "drafting…" : "draft with ai") { draft() }.disabled(idea.isEmpty || drafting)
                    }
                }
                if let draftError { Text(draftError).font(.caption).foregroundStyle(.orange) }
                TextField("name", text: $name)
                TextField("description", text: $desc)
                TextField("triggers (comma separated, empty = always)", text: $triggers)
                TextEditor(text: $skillBody).font(.system(size: 12, design: .monospaced)).frame(height: 160)
                HStack {
                    Button("cancel") { creating = false; editing = nil }
                    Spacer()
                    Button("save") {
                        env.skills.save(name: name, description: desc, triggers: triggers, body: skillBody, existing: editing)
                        creating = false; editing = nil
                    }.disabled(name.isEmpty || skillBody.isEmpty).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 480)
        }
    }

    private func draft() {
        drafting = true
        draftError = nil
        let req = GeminiRequest(model: env.settings.data.cheapModel,
                                system: "Write a skill for an AI assistant. Output exactly:\nNAME: <2-4 words>\nDESCRIPTION: <one line>\nTRIGGERS: <comma words or empty>\nBODY:\n<3-6 lines of clear instructions>",
                                turns: [GeminiTurn(role: .user, text: idea)], thinkingLevel: "off", maxOutputTokens: 600)
        Task {
            defer { drafting = false }
            let text: String
            do { text = try await env.gemini.complete(req).text } catch { draftError = Friendly.message(error); return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("NAME:") { name = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("DESCRIPTION:") { desc = line.dropFirst(12).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("TRIGGERS:") { triggers = line.dropFirst(9).trimmingCharacters(in: .whitespaces) }
            }
            if let r = text.range(of: "BODY:") { skillBody = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

struct ConnectionsTab: View {
    let env: AppEnvironment
    @State private var name = ""
    @State private var kind: MCPServerConfig.Kind = .stdio
    @State private var target = ""
    @State private var envText = ""

    var body: some View {
        Form {
            Section("add an mcp server") {
                Text("connect gmail, calendar, notion, linear, slack, github, supabase… through their MCP servers. sign-in (oauth) is handled by each server. tokens are stored in your keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("name (e.g. github)", text: $name)
                Picker("type", selection: $kind) {
                    Text("local command (stdio)").tag(MCPServerConfig.Kind.stdio)
                    Text("remote url (http)").tag(MCPServerConfig.Kind.http)
                }
                TextField(kind == .stdio ? "command, e.g. npx -y @modelcontextprotocol/server-github" : "https://…/mcp", text: $target)
                TextField("env vars (KEY=value per line) — optional", text: $envText, axis: .vertical).lineLimit(1...4)
                Button("add & connect") {
                    let cfg = MCPServerConfig(name: name, kind: kind, target: target)
                    env.mcp.servers.append(cfg)
                    if !envText.isEmpty { env.mcp.setEnv(envText, for: cfg.id) }
                    env.mcp.connect(cfg)
                    name = ""; target = ""; envText = ""
                }.disabled(name.isEmpty || target.isEmpty)
            }
            Section("servers") {
                if env.mcp.servers.isEmpty { Text("none yet").foregroundStyle(.secondary) }
                ForEach(env.mcp.servers) { s in
                    HStack {
                        Circle().fill(color(env.mcp.status[s.id])).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(s.name).fontWeight(.medium)
                            Text(label(env.mcp.status[s.id]) + " · " + s.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("reconnect") { env.mcp.connect(s) }
                        Button { env.mcp.remove(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("remove \(s.name)")
                    }
                }
            }
            Section {
                Text("tools from servers that aren't marked read-only always ask before running.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func label(_ s: MCPManager.Status?) -> String {
        switch s {
        case .connected(let n): "connected · \(n) tools"
        case .connecting: "connecting…"
        case .failed(let m): "failed: \(m)"
        default: "off"
        }
    }

    private func color(_ s: MCPManager.Status?) -> Color {
        switch s {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .orange
        default: .secondary
        }
    }
}
