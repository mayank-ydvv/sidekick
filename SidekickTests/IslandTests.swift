import XCTest
@testable import Sidekick

final class IslandTests: XCTestCase {
    func testMediaKeysDecode() {
        // data1 = keyCode << 16 | state << 8 (0xA down, 0xB up)
        XCTAssertEqual(EventTapManager.mediaKey(subtype: 8, data1: (0 << 16) | (0xA << 8))?.0, .volumeUp)
        XCTAssertEqual(EventTapManager.mediaKey(subtype: 8, data1: (1 << 16) | (0xA << 8))?.0, .volumeDown)
        XCTAssertEqual(EventTapManager.mediaKey(subtype: 8, data1: (7 << 16) | (0xB << 8))?.1, false)
        XCTAssertEqual(EventTapManager.mediaKey(subtype: 8, data1: (2 << 16) | (0xA << 8))?.0, .brightnessUp)
        XCTAssertNil(EventTapManager.mediaKey(subtype: 8, data1: (16 << 16) | (0xA << 8)))   // play key: macOS handles it
        XCTAssertNil(EventTapManager.mediaKey(subtype: 7, data1: 0))
    }

    func testTimerFormatting() {
        XCTAssertEqual(TimerStore.clock(299.2), "5:00")
        XCTAssertEqual(TimerStore.clock(3723), "1:02:03")
        XCTAssertEqual(TimerStore.describe(600), "10 min")
        XCTAssertEqual(TimerStore.describe(5400), "1 h 30 min")
        XCTAssertEqual(TimerStore.describe(45), "45 s")
    }

    func testMeetingLinks() {
        XCTAssertEqual(MeetingWatcher.findMeetingLink(in: "Join: https://us02web.zoom.us/j/123?pwd=x and call")?.host, "us02web.zoom.us")
        XCTAssertEqual(MeetingWatcher.findMeetingLink(in: "meet.google.com/abc https://meet.google.com/abc-defg-hij")?.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
        XCTAssertNil(MeetingWatcher.findMeetingLink(in: "Room 4B, https://example.com/agenda"))
    }

    func testIslandVoiceTags() {
        var p = TagParser()
        let e = p.push("On it. [TIMER seconds=600 label=\"Pasta\"] [TIMER minutes=2] [STOPWATCH action=\"reset\"] [MEDIA action=\"next\"] [TIMER action=\"cancel\"]")
        let tags = e.compactMap { if case .tag(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(tags, [.timer(seconds: 600, label: "Pasta", action: nil), .timer(seconds: 120, label: nil, action: nil),
                              .stopwatch(action: "reset"), .media(action: "next"), .timer(seconds: nil, label: nil, action: "cancel")])
    }

    @MainActor
    func testNowPlayingParsing() {
        let np = NowPlayingService()
        np.apply(["title": "Sunrise", "artist": "Example Band", "duration": 290.0, "elapsed": 10.0, "playing": 1,
                  "rate": 1.0, "timestamp": Date().timeIntervalSince1970, "bundle": "com.apple.Music"])
        XCTAssertEqual(np.track?.title, "Sunrise")
        XCTAssertEqual(np.track?.playing, true)
        XCTAssertTrue(np.showInClosedNotch)
        XCTAssertEqual(np.track!.position(), 10, accuracy: 1.5)
        np.apply(["title": ""])
        XCTAssertNil(np.track)
        XCTAssertFalse(np.showInClosedNotch)
    }

    @MainActor
    func testIslandPriorityAndLayout() {
        let hub = IslandHub()
        XCTAssertNil(hub.closedLayout)
        hub.nowPlaying.apply(["title": "Song", "playing": 1, "duration": 100.0, "elapsed": 1.0])
        XCTAssertEqual(hub.closedItem, .media)
        XCTAssertEqual(hub.closedLayout, .sides)
        hub.timers.startTimer(seconds: 60, label: "Tea")
        if case .timer = hub.closedItem {} else { XCTFail("timer should beat music: \(String(describing: hub.closedItem))") }
        hub.show(.init(kind: .bluetooth(name: "AirPods Pro", symbol: "airpodspro", battery: 80, connected: true), duration: 5))
        XCTAssertEqual(hub.closedLayout, .strip(44))
        hub.dismissAlert()
        hub.timers.cancelTimer()
        XCTAssertTrue(hub.hasCards)
        XCTAssertGreaterThan(hub.peekSize(notchHeight: 32).height, 150)
    }

    func testVirtualNotchMatchesTheMenuBar() {
        let g = NotchGeometry.forScreen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), auxLeft: nil, auxRight: nil,
                                        safeTop: 0, menuBarHeight: 25)
        XCTAssertTrue(g.isVirtual)
        XCTAssertEqual(g.rect.height, 25)
        XCTAssertEqual(g.rect.midX, 1280)
        XCTAssertEqual(g.rect.maxY, 1440)
    }

    func testCallsNeedTheCallAppItselfOnTheMic() {
        // Screen recording with the mic while WhatsApp is merely open: not a call.
        XCTAssertNil(SystemWatchers.callApp(capturing: ["com.apple.screencaptureui"]))
        XCTAssertNil(SystemWatchers.callApp(capturing: []))
        // WhatsApp (or its helper) actually recording: a call.
        XCTAssertEqual(SystemWatchers.callApp(capturing: ["net.whatsapp.WhatsApp"]), "WhatsApp")
        XCTAssertEqual(SystemWatchers.appBundle("us.zoom.xos.helper"), "us.zoom.xos")
        XCTAssertEqual(SystemWatchers.appBundle("com.google.Chrome.helper.renderer"), "com.google.Chrome")
        XCTAssertEqual(SystemWatchers.appBundle("com.apple.screencaptureui"), "com.apple.screencaptureui")
    }

    func testOnlyMeaningfulBluetoothDevicesAreAnnounced() {
        XCTAssertEqual(SystemWatchers.kind(major: 0x04, name: "AirPods Pro"), .audio)
        XCTAssertEqual(SystemWatchers.kind(major: 0x00, name: "Mayank's AirPods"), .audio)      // name wins over class
        XCTAssertEqual(SystemWatchers.kind(major: 0x05, name: "Magic Keyboard"), .peripheral)
        XCTAssertEqual(SystemWatchers.kind(major: 0x02, name: "Mayank's iPhone"), .ignore)      // Continuity / Handoff
        XCTAssertEqual(SystemWatchers.kind(major: 0x07, name: "Mayank's Apple Watch"), .ignore)
        XCTAssertEqual(SystemWatchers.kind(major: 0x01, name: "MacBook Pro"), .ignore)
    }
}
