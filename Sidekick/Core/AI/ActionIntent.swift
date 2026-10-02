import Foundation

/// Safety net for voice turns: when the user gave a command ("open the mac folder") and the reply promised to
/// do it ("opening it now") but the model forgot the [AGENT] tag, Sidekick starts the task itself.
enum ActionIntent {
    /// Verbs that mean "do something on my Mac" (not "point at" / "explain").
    static let verbs: Set<String> = [
        "open", "launch", "start", "play", "pause", "resume", "close", "quit", "search", "google", "click", "go", "navigate",
        "create", "make", "add", "set", "turn", "switch", "save", "move", "rename", "copy", "download", "install",
        "schedule", "remind", "book", "visit", "load", "run", "mute", "unmute", "skip", "shuffle", "maximize", "minimize",
    ]
    static let fillers: Set<String> = [
        "hey", "hi", "ok", "okay", "sidekick", "please", "pls", "can", "could", "would", "will", "you", "u", "just", "now",
        "quickly", "for", "me", "kindly", "yo", "bro", "bhai", "and",
    ]
    /// Reply phrases that promise an action.
    static let promises = [
        "opening", "launching", "playing", "searching", "starting", "closing", "creating", "on it", "i'll", "i will",
        "let me", "right away", "doing that", "done", "here you go", "getting", "pulling up", "bringing up", "heading to",
        "going to", "setting", "turning", "switching", "saving", "clicking", "navigating",
    ]

    /// Words in a reply that show it's carrying out *this* command (not just "here you go").
    static let doing: [String: [String]] = [
        "open": ["open", "pull up", "pulling up", "bring up", "bringing up"], "launch": ["launch", "open", "start"],
        "start": ["start", "launch", "open"], "play": ["play", "put on", "putting on", "queue"], "pause": ["paus"],
        "resume": ["resum", "play"], "close": ["clos"], "quit": ["quit", "clos"], "search": ["search", "look", "find"],
        "google": ["search", "google", "look"], "click": ["click", "press"], "go": ["go", "head", "open", "navigat"],
        "navigate": ["navigat", "go", "head"], "create": ["creat", "mak", "set"], "make": ["mak", "creat", "set"],
        "add": ["add"], "set": ["set"], "turn": ["turn", "switch"], "switch": ["switch", "turn"], "save": ["sav"],
        "move": ["mov"], "rename": ["renam"], "copy": ["cop"], "download": ["download"], "install": ["install"],
        "schedule": ["schedul", "add", "set"], "remind": ["remind", "set", "add"], "book": ["book"], "visit": ["visit", "open", "go"],
        "load": ["load", "open"], "run": ["run"], "mute": ["mut"], "unmute": ["unmut"], "skip": ["skip"], "shuffle": ["shuffl"],
        "maximize": ["maximi"], "minimize": ["minimi"],
    ]
    /// Replies that decline or ask back mean no task.
    static let refusals = ["can't", "cannot", "couldn't", "unable", "not able", "which one", "do you want me", "should i", "would you like me"]

    static func commandVerb(_ userText: String) -> String? {
        let words = userText.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard let first = words.first(where: { !fillers.contains($0) }), verbs.contains(first) else { return nil }
        return first
    }

    /// The reply says it's doing what was asked ("opening that folder", "I'll put on some lofi").
    static func promisesAction(_ reply: String, verb: String) -> Bool {
        let r = reply.lowercased().replacingOccurrences(of: "’", with: "'")
        if refusals.contains(where: { r.contains($0) }) { return false }
        guard promises.contains(where: { r.contains($0) }) || r.contains("ing ") else { return false }
        return (doing[verb] ?? [verb]).contains { r.contains($0) }
    }

    static func needsAgent(user: String, reply: String) -> Bool {
        guard let verb = commandVerb(user) else { return false }
        return promisesAction(reply, verb: verb)
    }

    // MARK: "Want me to open it?" → "yeah sure"

    static let offerPhrases = ["want me to", "should i", "shall i", "would you like me to", "do you want me to", "i can ",
                               "let me know if", "if you'd like", "if you want", "karu", "kar doon", "kar du"]

    /// The previous reply offered to *do* something on the Mac (not just explain more), and the user said yes.
    static func acceptedOffer(user: String, previousReply: String?) -> Bool {
        guard let prev = previousReply?.lowercased(), YesNo.answer(user) == true,
              user.split(separator: " ").count <= 8,
              offerPhrases.contains(where: prev.contains) else { return false }
        let words = prev.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains(where: verbs.contains)
    }
}
