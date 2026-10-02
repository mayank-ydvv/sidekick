import Foundation

/// Agent tools for buddies, routines and the notes wiki (they talk to main-actor stores).
enum BuddyTools {
    @MainActor
    static func make(store: BuddyStore, scheduler: RoutineScheduler, wiki: NotesWiki) -> [AgentTool] {
        [
            AgentTool(
                name: "buddy_create",
                description: "Create a persistent named buddy (an agent with its own role, memory and folder). Name: 2 friendly words describing its job. Optionally give it a routine.",
                parameters: Schema.object([
                    "name": Schema.string("2 friendly words, e.g. \"Inbox Buddy\", \"Day Summarizer\""),
                    "role": Schema.string("What this buddy does, in one or two sentences"),
                    "routine_prompt": Schema.string("Optional: what to do on schedule"),
                    "schedule": Schema.string("Optional: e.g. \"daily 21:00\", \"weekdays 9am\", \"weekly mon 08:00\", \"every 3 hours\""),
                ], required: ["name", "role"]),
                requiresConfirmation: { _, _ in false },
                run: { args, _ in
                    let name = args["name"] as? String ?? "New Buddy", role = args["role"] as? String ?? ""
                    let count = await MainActor.run { store.active.count }
                    guard count < 20 else { return .error("that's a lot of buddies already — archive some first") }
                    do {
                        let b = try await store.create(name: name, role: role)
                        var note = "created buddy \"\(b.name)\""
                        if let p = args["routine_prompt"] as? String, let s = args["schedule"] as? String, !p.isEmpty, !s.isEmpty {
                            _ = try await store.addRoutine(buddy: b, prompt: p, schedule: s)
                            await MainActor.run { scheduler.reschedule() }
                            note += " with routine (\(Schedule.parse(s)?.label ?? s))"
                        }
                        return ToolResult(text: note)
                    } catch { return .error(error.localizedDescription) }
                }),
            AgentTool(
                name: "routine_create",
                description: "Schedule an existing buddy to do something regularly.",
                parameters: Schema.object(["buddy": Schema.string("Buddy name"), "prompt": Schema.string("What to do"),
                                           "schedule": Schema.string("e.g. daily 21:00")], required: ["buddy", "prompt", "schedule"]),
                requiresConfirmation: { _, _ in false },
                run: { args, _ in
                    guard let name = args["buddy"] as? String, let b = await MainActor.run(body: { store.buddy(named: name) }) else {
                        return .error("no buddy with that name")
                    }
                    do {
                        let s = args["schedule"] as? String ?? ""
                        _ = try await store.addRoutine(buddy: b, prompt: args["prompt"] as? String ?? "", schedule: s)
                        await MainActor.run { scheduler.reschedule() }
                        return ToolResult(text: "\(b.name) will do that \(Schedule.parse(s)?.label ?? s)")
                    } catch { return .error(error.localizedDescription) }
                }),
            AgentTool(
                name: "buddy_list",
                description: "List buddies and their routines.",
                parameters: Schema.object([:]),
                requiresConfirmation: { _, _ in false },
                run: { _, _ in
                    let text = await MainActor.run { () -> String in
                        store.buddies.map { b in
                            let rs = store.routines(for: b).map { "  • \($0.prompt) — \(Schedule.parse($0.schedule)?.label ?? $0.schedule)\($0.enabled ? "" : " (paused)")" }
                            return "- \(b.name)\(b.archived ? " (archived)" : ""): \(b.rolePrompt)" + (rs.isEmpty ? "" : "\n" + rs.joined(separator: "\n"))
                        }.joined(separator: "\n")
                    }
                    return ToolResult(text: text.isEmpty ? "no buddies yet" : text)
                }),
            AgentTool(
                name: "wiki_save",
                description: "Save or add to a topic page in the user's notes wiki (~/Sidekick/Notes). Use for \"save this…\".",
                parameters: Schema.object(["topic": Schema.string("Short topic title"), "content": Schema.string("Markdown to save")],
                                          required: ["topic", "content"]),
                requiresConfirmation: { _, _ in false },
                run: { args, _ in
                    let topic = args["topic"] as? String ?? "Notes", content = args["content"] as? String ?? ""
                    let url = await MainActor.run { wiki.save(topic: topic, content: content) }
                    return ToolResult(text: "saved to notes: \(topic)", files: [url])
                }),
            AgentTool(
                name: "wiki_search",
                description: "Search the user's notes wiki; returns matching topics and the first page's text.",
                parameters: Schema.object(["query": Schema.string("What to look for")], required: ["query"]),
                requiresConfirmation: { _, _ in false },
                run: { args, _ in
                    let q = args["query"] as? String ?? ""
                    let (hits, first) = await MainActor.run { () -> ([String], String) in
                        let h = wiki.search(q)
                        return (h, h.first.map { wiki.read($0) } ?? "")
                    }
                    return ToolResult(text: hits.isEmpty ? "nothing in notes" : "topics: \(hits.joined(separator: ", "))\n\n\(first.prefix(4000))")
                }),
        ]
    }
}
