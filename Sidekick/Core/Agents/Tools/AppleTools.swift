import EventKit
import Foundation

enum AppleTools {
    static let all: [AgentTool] = [notesCreate, notesSearch, calendarList, calendarCreate, remindersCreate, remindersList]
    static let store = EKEventStore()

    static func appleScript(_ src: String) async -> (String?, String?) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
                cont.resume(returning: (out?.stringValue, err?[NSAppleScript.errorMessage] as? String))
            }
        }
    }

    static func asLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let notesCreate = AgentTool(
        name: "notes_create",
        description: "Create a note in Apple Notes.",
        parameters: Schema.object(["title": Schema.string("Note title"), "body": Schema.string("Note text")], required: ["title", "body"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            let title = args["title"] as? String ?? "Note"
            let body = (args["body"] as? String ?? "").replacingOccurrences(of: "\n", with: "<br>")
            let (_, err) = await appleScript("tell application \"Notes\" to make new note with properties {name:\(asLiteral(title)), body:\(asLiteral("<h1>\(title)</h1>" + body))}")
            return err.map { .error($0) } ?? ToolResult(text: "note \"\(title)\" created")
        })

    static let notesSearch = AgentTool(
        name: "notes_search",
        description: "Find Apple Notes whose title contains the text; returns titles.",
        parameters: Schema.object(["query": Schema.string("Text to look for in note titles")], required: ["query"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            let q = args["query"] as? String ?? ""
            let (out, err) = await appleScript("tell application \"Notes\" to get name of every note whose name contains \(asLiteral(q))")
            return err.map { .error($0) } ?? ToolResult(text: out ?? "no matching notes")
        })

    /// "granted", "denied", "not asked yet" or "limited" for Settings / probes.
    static func accessDescription(_ type: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess, .authorized: "granted"
        case .writeOnly: "add-only"
        case .denied, .restricted: "denied"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    static func requestAccess(_ type: EKEntityType) async -> Bool {
        do {
            return type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        } catch { return false }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static let calendarList = AgentTool(
        name: "calendar_list_events",
        description: "List calendar events in the next N days.",
        parameters: Schema.object(["days": Schema.integer("How many days ahead (default 1)")]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard await requestAccess(.event) else { return .error("calendar access was not granted") }
            let days = (args["days"] as? Int) ?? 1
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start)!
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            let df = DateFormatter(); df.dateFormat = "EEE d MMM HH:mm"
            let lines = events.prefix(50).map { "\(df.string(from: $0.startDate)) – \($0.title ?? "")" }
            return ToolResult(text: lines.isEmpty ? "no events" : lines.joined(separator: "\n"))
        })

    static let calendarCreate = AgentTool(
        name: "calendar_create_event",
        description: "Create a calendar event. Dates in ISO 8601 local time, e.g. 2026-10-02T15:00.",
        parameters: Schema.object(["title": Schema.string("Event title"), "start": Schema.string("Start"),
                                   "end": Schema.string("End (optional, default +1h)"), "notes": Schema.string("Notes")],
                                  required: ["title", "start"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard await requestAccess(.event) else { return .error("calendar access was not granted") }
            guard let start = date(args["start"]) else { return .error("couldn't read the start date") }
            let e = EKEvent(eventStore: store)
            e.title = args["title"] as? String ?? "Event"
            e.startDate = start
            e.endDate = date(args["end"]) ?? start.addingTimeInterval(3600)
            e.notes = args["notes"] as? String
            e.calendar = store.defaultCalendarForNewEvents
            try store.save(e, span: .thisEvent)
            return ToolResult(text: "event \"\(e.title ?? "")\" added")
        })

    static let remindersCreate = AgentTool(
        name: "reminders_create",
        description: "Create a reminder, optionally with a due date (ISO 8601).",
        parameters: Schema.object(["title": Schema.string("Reminder"), "due": Schema.string("Due date/time (optional)")], required: ["title"]),
        requiresConfirmation: { _, _ in false },
        run: { args, _ in
            guard await requestAccess(.reminder) else { return .error("reminders access was not granted") }
            let r = EKReminder(eventStore: store)
            r.title = args["title"] as? String ?? "Reminder"
            r.calendar = store.defaultCalendarForNewReminders()
            if let due = date(args["due"]) {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                r.addAlarm(EKAlarm(absoluteDate: due))
            }
            try store.save(r, commit: true)
            return ToolResult(text: "reminder \"\(r.title ?? "")\" added")
        })

    static let remindersList = AgentTool(
        name: "reminders_list",
        description: "List incomplete reminders.",
        parameters: Schema.object([:]),
        requiresConfirmation: { _, _ in false },
        run: { _, _ in
            guard await requestAccess(.reminder) else { return .error("reminders access was not granted") }
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let titles: [String] = await withCheckedContinuation { cont in
                store.fetchReminders(matching: pred) { rs in cont.resume(returning: (rs ?? []).prefix(50).compactMap(\.title)) }
            }
            return ToolResult(text: titles.isEmpty ? "no open reminders" : titles.map { "- " + $0 }.joined(separator: "\n"))
        })
}
