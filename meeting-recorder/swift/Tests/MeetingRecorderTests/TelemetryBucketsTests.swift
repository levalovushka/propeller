import XCTest
@testable import PropellerPure

/// Bucket boundaries, pinned. Every funnel chart is drawn from these, and a
/// wrong edge is invisible in the chart — it only shows up as a conclusion
/// nobody can reproduce.
final class TelemetryBucketsTests: XCTestCase {

    func testEachDurationEdgeCountsUpward() {
        XCTAssertEqual(TelemetryBuckets.duration(0), "<1m")
        XCTAssertEqual(TelemetryBuckets.duration(59), "<1m")
        XCTAssertEqual(TelemetryBuckets.duration(60), "1-15m")
        XCTAssertEqual(TelemetryBuckets.duration(899), "1-15m")
        XCTAssertEqual(TelemetryBuckets.duration(900), "15-60m")
        XCTAssertEqual(TelemetryBuckets.duration(3599), "15-60m")
        XCTAssertEqual(TelemetryBuckets.duration(3600), "60m+")
    }

    /// The ten-second edge is the one the auto-detect verdict rests on: a
    /// recording killed inside it is a wrong call detection, not a person
    /// changing their mind.
    func testTheTenSecondEdgeIsWhereAWrongDetectionLives() {
        XCTAssertEqual(TelemetryBuckets.age(0), "<10s")
        XCTAssertEqual(TelemetryBuckets.age(9.9), "<10s")
        XCTAssertEqual(TelemetryBuckets.age(10), "10-60s")
        XCTAssertEqual(TelemetryBuckets.age(59), "10-60s")
        XCTAssertEqual(TelemetryBuckets.age(60), "1-5m")
        XCTAssertEqual(TelemetryBuckets.age(299), "1-5m")
        XCTAssertEqual(TelemetryBuckets.age(300), "5m+")
    }
}
