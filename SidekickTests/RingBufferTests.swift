import XCTest
@testable import Sidekick

final class RingBufferTests: XCTestCase {
    func testAppendAndSnapshotInOrder() {
        var rb = RingBuffer(capacity: 5)
        rb.append([1, 2, 3])
        XCTAssertEqual(rb.snapshot(), [1, 2, 3])
        rb.append([4, 5, 6, 7])
        XCTAssertEqual(rb.count, 5)
        XCTAssertEqual(rb.snapshot(), [3, 4, 5, 6, 7])
    }

    func testOversizedAppendKeepsTail() {
        var rb = RingBuffer(capacity: 3)
        rb.append([1, 2, 3, 4, 5, 6])
        XCTAssertEqual(rb.snapshot(), [4, 5, 6])
    }

    func testResetAndEmpty() {
        var rb = RingBuffer(capacity: 4)
        XCTAssertEqual(rb.snapshot(), [])
        rb.append([1, 2])
        rb.reset()
        XCTAssertEqual(rb.snapshot(), [])
        rb.append([9])
        XCTAssertEqual(rb.snapshot(), [9])
    }

    func testManySmallWritesMatchReference() {
        var rb = RingBuffer(capacity: 37)
        var reference: [Float] = []
        for i in 0..<500 {
            let chunk = (0..<(i % 11)).map { Float(i * 100 + $0) }
            rb.append(chunk)
            reference += chunk
            XCTAssertEqual(rb.snapshot(), Array(reference.suffix(37)))
        }
    }
}

final class VADTests: XCTestCase {
    func testTrimsLeadingAndTrailingSilence() {
        let silence = [Float](repeating: 0, count: 320 * 50)
        let speech = (0..<(320 * 20)).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        let trimmed = VAD.trimSilence(silence + speech + silence, padding: 2)
        XCTAssertEqual(trimmed.count, 320 * 24)
    }

    func testAllSilenceReturnsEmpty() {
        XCTAssertTrue(VAD.trimSilence([Float](repeating: 0.001, count: 16_000)).isEmpty)
    }

    func testRMS() {
        let s: [Float] = [1, -1, 1, -1]
        XCTAssertEqual(VAD.rms(s[...]), 1, accuracy: 1e-6)
    }
}
