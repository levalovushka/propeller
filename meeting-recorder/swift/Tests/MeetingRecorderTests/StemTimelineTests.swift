import XCTest
@testable import PropellerPure

/// Named after what a person heard: the far end arriving twice, half a second
/// apart, because the stems were summed from index zero.
final class StemTimelineTests: XCTestCase {

    func testTheSystemStemStartsWhereTheMicrophoneClockSaysItDid() {
        // The offset measured on a real meeting.
        XCTAssertEqual(StemTimeline.systemStartFrame(offsetSeconds: 0.484, sampleRate: 16_000), 7_744)
    }

    func testNoOffsetMeansTheOldBehaviour() {
        XCTAssertEqual(StemTimeline.systemStartFrame(offsetSeconds: 0, sampleRate: 16_000), 0)
    }

    /// A missing measurement must not shift audio to a guess — mic-only
    /// recordings and pre-1.14 files arrive here as zero.
    func testNonsenseOffsetsFallBackToNoShift() {
        XCTAssertEqual(StemTimeline.systemStartFrame(offsetSeconds: -1, sampleRate: 16_000), 0)
        XCTAssertEqual(StemTimeline.systemStartFrame(offsetSeconds: .nan, sampleRate: 16_000), 0)
        XCTAssertEqual(StemTimeline.systemStartFrame(offsetSeconds: .infinity, sampleRate: 16_000), 0)
        XCTAssertEqual(StemTimeline.systemStartFrame(offsetSeconds: 1, sampleRate: 0), 0)
    }

    func testTheMixHoldsWhicheverStemEndsLast() {
        // Microphone longer than the shifted system stem.
        XCTAssertEqual(
            StemTimeline.mixedFrameCount(micFrames: 100_000, systemFrames: 50_000, systemStartFrame: 7_744),
            100_000
        )
        // System stem runs past the end of the microphone one: the mic writer is
        // stopped first, so this is the normal case, not an edge one.
        XCTAssertEqual(
            StemTimeline.mixedFrameCount(micFrames: 100_000, systemFrames: 99_000, systemStartFrame: 7_744),
            106_744
        )
    }

    func testEmptyStemsDoNotProduceNegativeLengths() {
        XCTAssertEqual(
            StemTimeline.mixedFrameCount(micFrames: 0, systemFrames: 0, systemStartFrame: 0),
            0
        )
        XCTAssertEqual(
            StemTimeline.mixedFrameCount(micFrames: 0, systemFrames: 16_000, systemStartFrame: 7_744),
            23_744
        )
    }
}
