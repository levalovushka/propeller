import XCTest
import PropellerPure

final class SummaryTypewriterTests: XCTestCase {

    func testHiddenBeforeHead() {
        // head = 0.2 * (10+2) = 2.4 → index 5 still ahead
        XCTAssertEqual(
            SummaryTypewriter.alpha(at: 5, count: 10, progress: 0.2, softness: 2),
            0,
            accuracy: 0.001
        )
    }

    func testFullyVisibleBehindSoftEdge() {
        // head = 0.8 * 12 = 9.6 → indices 0...7 fully on (t >= 1)
        XCTAssertEqual(
            SummaryTypewriter.alpha(at: 0, count: 10, progress: 0.8, softness: 2),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SummaryTypewriter.alpha(at: 7, count: 10, progress: 0.8, softness: 2),
            1,
            accuracy: 0.001
        )
    }

    func testSoftEdgeIsBetween() {
        // head = 0.5 * 12 = 6, index 5 → t = (6-5)/2 = 0.5 → smoothstep 0.5
        let a = SummaryTypewriter.alpha(at: 5, count: 10, progress: 0.5, softness: 2)
        XCTAssertEqual(a, 0.5, accuracy: 0.001)
    }

    func testProgressZeroAndOne() {
        XCTAssertEqual(SummaryTypewriter.alpha(at: 0, count: 5, progress: 0, softness: 2), 0, accuracy: 0.001)
        XCTAssertEqual(SummaryTypewriter.alpha(at: 4, count: 5, progress: 1, softness: 2), 1, accuracy: 0.001)
    }

    func testDurationClamped() {
        XCTAssertEqual(
            SummaryTypewriter.duration(count: 10, secondsPerChar: 0.01, minimum: 0.2, maximum: 1),
            0.2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SummaryTypewriter.duration(count: 1000, secondsPerChar: 0.01, minimum: 0.2, maximum: 1),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SummaryTypewriter.duration(count: 40, secondsPerChar: 0.01, minimum: 0.2, maximum: 1),
            0.4,
            accuracy: 0.0001
        )
    }
}
