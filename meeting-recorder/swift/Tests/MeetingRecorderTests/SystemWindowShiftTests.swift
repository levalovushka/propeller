import XCTest
@testable import SpeakerMatchingCore

/// Speaker attribution compares energy between the two stems inside the windows
/// where a speaker talks. The windows are timed against the mix, which runs on
/// the microphone's clock — the system stem's file starts later, so reading it
/// with the same numbers compares one person's words against a different
/// half-second of the other stem.
final class SystemWindowShiftTests: XCTestCase {

    func testWindowsMoveIntoTheSystemStemsOwnTimeline() {
        let windows = [10.0...12.0, 30.0...31.5]
        let shifted = AudioSourceEnergyClassifier.systemWindows(windows, systemStemOffset: 0.484)
        XCTAssertEqual(shifted.count, 2)
        XCTAssertEqual(shifted[0].lowerBound, 9.516, accuracy: 1e-9)
        XCTAssertEqual(shifted[0].upperBound, 11.516, accuracy: 1e-9)
        XCTAssertEqual(shifted[1].lowerBound, 29.516, accuracy: 1e-9)
    }

    func testNoOffsetLeavesWindowsAlone() {
        let windows = [10.0...12.0]
        XCTAssertEqual(AudioSourceEnergyClassifier.systemWindows(windows, systemStemOffset: 0), windows)
        XCTAssertEqual(AudioSourceEnergyClassifier.systemWindows(windows, systemStemOffset: .nan), windows)
    }

    /// Speech in the first half-second happened before the system stem existed.
    /// Reading it from the file's start is the only honest answer; inventing
    /// negative time is not.
    func testAWindowFromBeforeTheStemStartsIsClampedNotDropped() {
        let shifted = AudioSourceEnergyClassifier.systemWindows([0.1...1.0], systemStemOffset: 0.484)
        XCTAssertEqual(shifted.count, 1)
        XCTAssertEqual(shifted[0].lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(shifted[0].upperBound, 0.516, accuracy: 1e-9)
    }

    func testAWindowEntirelyBeforeTheStemDisappears() {
        XCTAssertTrue(
            AudioSourceEnergyClassifier.systemWindows([0.0...0.3], systemStemOffset: 0.484).isEmpty
        )
    }

    /// Without a system stem to compare against there is nothing to classify —
    /// the caller must not read "no energy" as "not the system".
    func testClassifierStillNeedsBothSides() {
        XCTAssertEqual(
            AudioSourceEnergyClassifier.classify(microphoneEnergy: 1e-3, systemEnergy: nil),
            .microphone
        )
        XCTAssertEqual(
            AudioSourceEnergyClassifier.classify(microphoneEnergy: nil, systemEnergy: nil),
            .unknown
        )
    }

    /// Both stems carry the same meeting, so "who spoke" is a question about
    /// which one was louder inside the speaker's own windows — and only clearly
    /// louder counts. Two stems within the ratio are both sides talking at
    /// once, which is a third answer, not a tie to be broken.
    func testTheLouderStemWinsOnlyWhenItIsClearlyLouder() {
        XCTAssertEqual(
            AudioSourceEnergyClassifier.classify(microphoneEnergy: 0.01, systemEnergy: 0.001),
            .microphone
        )
        XCTAssertEqual(
            AudioSourceEnergyClassifier.classify(microphoneEnergy: 0.001, systemEnergy: 0.01),
            .system
        )
        XCTAssertEqual(
            AudioSourceEnergyClassifier.classify(microphoneEnergy: 0.01, systemEnergy: 0.009),
            .mixed
        )
    }

    /// The stems are found by name beside the mix, never by an index, so these
    /// two names are a contract with every recording already on disk: renaming
    /// them orphans the stems of every past meeting silently.
    func testStemsAreFoundBesideTheMixByName() {
        let stems = AudioSourceStemURLs.expectedSiblings(
            for: URL(fileURLWithPath: "/tmp/20260415_120000.wav")
        )
        XCTAssertEqual(stems.microphoneURL.lastPathComponent, "20260415_120000.mic.wav")
        XCTAssertEqual(stems.systemURL.lastPathComponent, "20260415_120000.sys.wav")
    }
}
