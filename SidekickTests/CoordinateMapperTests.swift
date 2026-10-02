import XCTest
@testable import Sidekick

final class CoordinateMapperTests: XCTestCase {
    // Retina MacBook: 1512x982 pt display, screenshot downscaled to 1280x831.
    let builtIn = CoordinateMapper(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   imageSize: CGSize(width: 1280, height: 831))

    func testCornersAndCenter() {
        let tl = builtIn.screenPoint(normY: 0, normX: 0)
        XCTAssertEqual(tl.x, 0, accuracy: 0.01); XCTAssertEqual(tl.y, 982, accuracy: 0.01)
        let br = builtIn.screenPoint(normY: 1000, normX: 1000)
        XCTAssertEqual(br.x, 1512, accuracy: 0.01); XCTAssertEqual(br.y, 0, accuracy: 0.01)
        let c = builtIn.screenPoint(normY: 500, normX: 500)
        XCTAssertEqual(c.x, 756, accuracy: 0.01); XCTAssertEqual(c.y, 491, accuracy: 0.01)
    }

    func testImagePixels() {
        let p = builtIn.imagePoint(normY: 412, normX: 733)
        XCTAssertEqual(p.x, 938.24, accuracy: 0.01)
        XCTAssertEqual(p.y, 342.37, accuracy: 0.01)
    }

    func testExternalDisplayLeftAndAbove() {
        // External 1920x1080 display placed left of and higher than the primary.
        let ext = CoordinateMapper(displayFrame: CGRect(x: -1920, y: 300, width: 1920, height: 1080),
                                   imageSize: CGSize(width: 1280, height: 720))
        let p = ext.screenPoint(normY: 250, normX: 750)
        XCTAssertEqual(p.x, -480, accuracy: 0.01)
        XCTAssertEqual(p.y, 300 + 1080 - 270, accuracy: 0.01)
    }

    func testRoundTripScreenNormalized() {
        let ext = CoordinateMapper(displayFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                                   imageSize: CGSize(width: 1280, height: 720))
        for (y, x) in [(0.0, 0.0), (123.0, 987.0), (1000.0, 1000.0), (500.0, 250.0)] {
            let n = ext.normalized(screen: ext.screenPoint(normY: y, normX: x))
            XCTAssertEqual(n.y, y, accuracy: 0.001)
            XCTAssertEqual(n.x, x, accuracy: 0.001)
        }
    }

    func testImagePixelToScreen() {
        let p = builtIn.screenPoint(imagePixel: CGPoint(x: 640, y: 415.5))
        XCTAssertEqual(p.x, 756, accuracy: 0.01)
        XCTAssertEqual(p.y, 491, accuracy: 0.01)
    }

    func testClampsOutOfRange() {
        let p = builtIn.screenPoint(normY: -50, normX: 1200)
        XCTAssertEqual(p.x, 1512, accuracy: 0.01)
        XCTAssertEqual(p.y, 982, accuracy: 0.01)
    }

    func testQuartzConversion() {
        let q = CoordinateMapper.quartz(fromAppKit: CGPoint(x: 10, y: 900), primaryHeight: 982)
        XCTAssertEqual(q, CGPoint(x: 10, y: 82))
        XCTAssertEqual(CoordinateMapper.appKit(fromQuartz: q, primaryHeight: 982), CGPoint(x: 10, y: 900))
    }

    func testDownscale() {
        XCTAssertEqual(CoordinateMapper.downscaledSize(for: CGSize(width: 3024, height: 1964)), CGSize(width: 1280, height: 831))
        XCTAssertEqual(CoordinateMapper.downscaledSize(for: CGSize(width: 1000, height: 600)), CGSize(width: 1000, height: 600))
        XCTAssertEqual(CoordinateMapper.downscaledSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 720, height: 1280))
    }
}

final class TranscriptCleanTests: XCTestCase {
    func testTranscriptFixesTheAppName() {
        XCTAssertEqual(TalkCoordinator.cleanTranscript("High side cake, how are you?"), "Hi Sidekick, how are you?")
        XCTAssertEqual(TalkCoordinator.cleanTranscript("hey side kick open notes"), "hey Sidekick open notes")
        XCTAssertEqual(TalkCoordinator.cleanTranscript("the side of the cake"), "the side of the cake")
    }

    func testRemovesWhisperMarkers() {
        XCTAssertEqual(TalkCoordinator.cleanTranscript(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(TalkCoordinator.cleanTranscript("(music) what's on my screen?"), "what's on my screen?")
        XCTAssertEqual(TalkCoordinator.cleanTranscript(" ... "), "")
    }
}
