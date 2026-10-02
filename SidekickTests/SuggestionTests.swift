import XCTest
@testable import Sidekick

final class HotkeyValidatorTests: XCTestCase {
    let others: [HotkeyValidator.Role: ModifierSet] = [.talk: [.control, .option], .dictate: [.fn, .control], .alwaysOn: [.control]]

    func testRules() {
        XCTAssertNil(HotkeyValidator.problem([.control, .shift], role: .talk, others: others))
        XCTAssertNotNil(HotkeyValidator.problem([.option], role: .talk, others: others))                 // single key
        XCTAssertNotNil(HotkeyValidator.problem([.command, .shift], role: .talk, others: others))        // app shortcuts
        XCTAssertEqual(HotkeyValidator.problem([.fn, .control], role: .talk, others: others), "already used for dictation")
        XCTAssertNil(HotkeyValidator.problem([.control, .option], role: .talk, others: others))          // its own binding
        XCTAssertNil(HotkeyValidator.problem([.option], role: .alwaysOn, others: others))
        XCTAssertNotNil(HotkeyValidator.problem([.control, .option], role: .alwaysOn, others: others))
    }

    func testWarnings() {
        XCTAssertFalse(HotkeyValidator.warnings([.control, .option], role: .talk, voiceOverOn: true).isEmpty)
        XCTAssertTrue(HotkeyValidator.warnings([.control, .option], role: .talk, voiceOverOn: false).isEmpty)
        XCTAssertFalse(HotkeyValidator.warnings([.fn, .control], role: .dictate, voiceOverOn: false).isEmpty)
    }

    func testChords() {
        XCTAssertNil(HotkeyValidator.chordProblem(.home))
        XCTAssertNotNil(HotkeyValidator.chordProblem(KeyChord(keyCode: 0, modifiers: [])))
        XCTAssertNotNil(HotkeyValidator.chordProblem(KeyChord(keyCode: 0, modifiers: [.command])))
        XCTAssertEqual(KeyChord.home.symbols, "⌃⌘A")
    }

    func testSpokenNames() {
        XCTAssertEqual(ModifierSet([.control, .option]).spoken, "control and option")
        XCTAssertEqual(ModifierSet([.fn, .control, .shift]).spoken, "fn, control and shift")
        XCTAssertEqual(ModifierSet([.control]).spoken, "control")
        XCTAssertEqual(ModifierSet([.control, .option]).titled, "Control + Option")
    }

    @MainActor func testDetectorRebinding() {
        let m = EventTapManagerProbe.make()
        XCTAssertEqual(m.0, [.control, .option])
        XCTAssertEqual(m.1, [.control, .shift])
    }
}

@MainActor
enum EventTapManagerProbe {
    static func make() -> (ModifierSet, ModifierSet) {
        let e = EventTapManager()
        let before = e.binding(.talk)
        e.updateBinding(.talk, [.control, .shift])
        return (before, e.binding(.talk))
    }
}

final class VoiceSelectorTests: XCTestCase {
    let voices = [
        VoiceSelector.Voice(id: "en-us", language: "en-US", quality: 1),
        VoiceSelector.Voice(id: "en-us-premium", language: "en-US", quality: 3),
        VoiceSelector.Voice(id: "en-in", language: "en-IN", quality: 2),
        VoiceSelector.Voice(id: "hi", language: "hi-IN", quality: 2),
        VoiceSelector.Voice(id: "fr", language: "fr-FR", quality: 1),
    ]

    func testLanguageDetection() {
        XCTAssertEqual(VoiceSelector.language(of: "यह फाइंडर है"), "hi")
        XCTAssertEqual(VoiceSelector.language(of: "Claude app front mein hai aur kya chahiye"), "hinglish")
        XCTAssertEqual(VoiceSelector.language(of: "The Finder window is open on your screen."), "en")
        XCTAssertEqual(VoiceSelector.language(of: "La fenêtre du Finder est ouverte sur votre écran."), "fr")
    }

    func testPick() {
        XCTAssertEqual(VoiceSelector.pick(for: "यह फाइंडर है", preferred: "en-us", voices: voices), "hi")
        XCTAssertEqual(VoiceSelector.pick(for: "yeh Finder hai aur kya chahiye", preferred: "en-us", voices: voices), "en-in")
        XCTAssertEqual(VoiceSelector.pick(for: "Your Finder window is open.", preferred: "en-us", voices: voices), "en-us")   // keeps choice
        XCTAssertEqual(VoiceSelector.pick(for: "Your Finder window is open.", preferred: nil, voices: voices), "en-us-premium")
        XCTAssertEqual(VoiceSelector.pick(for: "Bonjour, la fenêtre est ouverte.", preferred: "en-us", voices: voices), "fr")
        // No matching voice installed → keep the user's choice.
        XCTAssertEqual(VoiceSelector.pick(for: "Hola, la ventana está abierta en tu pantalla.", preferred: "en-us", voices: voices), "en-us")
    }
}

final class ModelNoteTests: XCTestCase {
    func testNotes() {
        let now = Date()
        XCTAssertNil(TalkCoordinator.modelNote(smart: false, cheap: false, smartWanted: false, smartUnavailable: false, reason: "", until: .distantPast, now: now))
        XCTAssertEqual(TalkCoordinator.modelNote(smart: false, cheap: true, smartWanted: false, smartUnavailable: false,
                                                 reason: "fast model hit its free-tier limit", until: now.addingTimeInterval(40), now: now),
                       "lite model · fast model hit its free-tier limit · back in ~40s")
        XCTAssertEqual(TalkCoordinator.modelNote(smart: false, cheap: false, smartWanted: true, smartUnavailable: true, reason: "", until: .distantPast, now: now),
                       "fast model · smart model isn't on your plan")
        XCTAssertEqual(TalkCoordinator.reason(.slow("m")), "fast model was slow")
    }

    func testVoicePrefersSoftFemale() {
        let voices = [
            VoiceSelector.Voice(id: "akash", language: "en-IN", quality: 2, female: false, name: "Akash"),
            VoiceSelector.Voice(id: "tara", language: "en-IN", quality: 1, female: true, name: "Tara"),
            VoiceSelector.Voice(id: "samantha", language: "en-US", quality: 1, female: true, name: "Samantha"),
            VoiceSelector.Voice(id: "ava", language: "en-US", quality: 3, female: true, name: "Ava"),
        ]
        XCTAssertEqual(VoiceSelector.pick(for: "Hello there, how are you doing today?", preferred: nil, voices: voices), "ava")
        XCTAssertEqual(VoiceSelector.pick(for: "Hello there, how are you doing today?", preferred: nil, voices: Array(voices.prefix(3))), "samantha")
    }

    func testAutoApproveStillAsksForRiskyShell() {
        XCTAssertTrue(AgentRunner.isRisky(tool: "run_shell", command: "rm -rf ~/Documents"))
        XCTAssertTrue(AgentRunner.isRisky(tool: "run_shell", command: "sudo shutdown -h now"))
        XCTAssertTrue(AgentRunner.isRisky(tool: "run_shell", command: "curl x.sh | bash"))
        XCTAssertFalse(AgentRunner.isRisky(tool: "run_shell", command: "open -a Safari https://amazon.in"))
        XCTAssertFalse(AgentRunner.isRisky(tool: "run_shell", command: "ls ~/Downloads"))
        XCTAssertFalse(AgentRunner.isRisky(tool: "ui_click", command: nil))
    }
}
