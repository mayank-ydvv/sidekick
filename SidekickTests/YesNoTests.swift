import XCTest
@testable import Sidekick

final class YesNoTests: XCTestCase {
    func testShortAnswers() {
        for y in ["Yes.", "yeah sure", "Yeah, sure!", "ok", "okay go ahead", "haan", "Ha!", "theek hai", "do it", "sure thing", "हाँ"] {
            XCTAssertEqual(YesNo.answer(y), true, y)
        }
        for n in ["No.", "nope", "nah not now", "don't", "cancel that", "nahi", "नहीं", "no, wait yes"] {
            XCTAssertEqual(YesNo.answer(n), false, n)
        }
    }

    func testWordsInsideOtherWordsDontCount() {
        XCTAssertNil(YesNo.answer("I know what I need now"))
        XCTAssertNil(YesNo.answer("book a table in the format I like"))
        XCTAssertNil(YesNo.answer("what's on my screen"))
    }

    func testAcceptingAnOfferStartsTheTask() {
        XCTAssertTrue(ActionIntent.acceptedOffer(user: "yeah sure", previousReply: "Want me to open your Downloads folder?"))
        XCTAssertTrue(ActionIntent.acceptedOffer(user: "haan", previousReply: "Should I play some lofi on Spotify for you?"))
        XCTAssertFalse(ActionIntent.acceptedOffer(user: "yeah sure", previousReply: "Want me to explain that in more detail?"))
        XCTAssertFalse(ActionIntent.acceptedOffer(user: "no thanks", previousReply: "Want me to open your Downloads folder?"))
        XCTAssertFalse(ActionIntent.acceptedOffer(user: "yes", previousReply: nil))
    }

    func testShortClipsArePaddedForWhisper() {
        let clip = [Float](repeating: 0.5, count: 12_000)   // 0.75 s
        let padded = TalkCoordinator.padShort(clip, to: 1.5)
        XCTAssertEqual(padded.count, 24_000)
        XCTAssertEqual(padded[4_800], 0.5)                    // speech starts after 0.3 s of silence
        XCTAssertEqual(TalkCoordinator.padShort([Float](repeating: 0.1, count: 30_000), to: 1.5).count, 30_000)
    }
}
