import XCTest
@testable import Sidekick

final class ActionIntentTests: XCTestCase {
    func testCommandsThatPromiseAnActionStartATask() {
        XCTAssertTrue(ActionIntent.needsAgent(user: "Open the Mac folder.", reply: "Opening that Mac folder for you right now."))
        XCTAssertTrue(ActionIntent.needsAgent(user: "hey sidekick can you play some lofi", reply: "On it, putting on some lofi!"))
        XCTAssertTrue(ActionIntent.needsAgent(user: "please launch spotify", reply: "Sure, I'll open Spotify."))
    }

    func testQuestionsAndPointingDontStartTasks() {
        XCTAssertFalse(ActionIntent.needsAgent(user: "what's on my screen?", reply: "Let me look — it's your desktop."))
        XCTAssertFalse(ActionIntent.needsAgent(user: "where is the save button", reply: "It's right here, I'll point at it."))
        XCTAssertFalse(ActionIntent.needsAgent(user: "open the mac folder", reply: "I can't find a folder with that name."))
        XCTAssertFalse(ActionIntent.needsAgent(user: "make me a poem about rain", reply: "Here you go! Soft rain on the window…"))
        XCTAssertFalse(ActionIntent.needsAgent(user: "set the record straight, who won?", reply: "Here's what happened: Brazil won."))
        XCTAssertFalse(ActionIntent.needsAgent(user: "open spotify", reply: "Do you want me to open Spotify or the web player?"))
    }

    func testLocateFindsFoldersByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locate-\(UUID().uuidString)")
        let mac = root.appendingPathComponent("Desktop/mac", isDirectory: true)
        let deep = root.appendingPathComponent("Desktop/projects/Report Final.pdf")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: deep.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = [root.appendingPathComponent("Desktop")]
        XCTAssertEqual(LocalTools.locate("the mac folder", roots: roots, spotlight: false)?.lastPathComponent, "mac")
        XCTAssertEqual(LocalTools.locate("Mac", roots: roots, spotlight: false)?.lastPathComponent, "mac")
        XCTAssertEqual(LocalTools.locate("report final", roots: roots, spotlight: false)?.lastPathComponent, "Report Final.pdf")
        XCTAssertNil(LocalTools.locate("nothing-here", roots: roots, spotlight: false))
        XCTAssertEqual(LocalTools.locate(mac.path, spotlight: false)?.path, mac.path)
    }
}
