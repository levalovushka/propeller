import XCTest
@testable import PropellerPure

/// Invariant I6: any status string an existing `recordings.json` can hold must
/// decode. This is the one place in the state refactor where a mistake costs a
/// user their archive, so it is tested before anything reads the enum.
final class RecordingStageTests: XCTestCase {

    /// Wire shape of `recordings.json` — the enum sits under the `status` key.
    private struct Row: Codable, Equatable {
        let status: RecordingStage
    }

    private func decode(_ json: String) throws -> RecordingStage {
        try JSONDecoder().decode(Row.self, from: Data(json.utf8)).status
    }

    // MARK: - Migration

    func testEveryShippedStatusStringDecodes() throws {
        let shipped: [(String, RecordingStage)] = [
            ("recording", .recording),
            ("recorded", .recorded),
            ("transcribing", .transcribing),
            ("transcribed_raw", .transcribedRaw),
            ("transcribed", .transcribed),
            ("saved", .saved),
        ]
        for (raw, expected) in shipped {
            XCTAssertEqual(try decode(#"{"status":"\#(raw)"}"#), expected, raw)
        }
    }

    func testUnknownStatusFallsBackInsteadOfThrowing() throws {
        // A downgrade after `summarized` ships, or a hand-edited index.
        XCTAssertEqual(try decode(#"{"status":"nonsense"}"#), .recorded)
        XCTAssertEqual(try decode(#"{"status":""}"#), .recorded)
    }

    func testEncodingKeepsTheOldWireStrings() throws {
        // An older build must still read an index this one wrote.
        for stage in RecordingStage.allCases {
            let data = try JSONEncoder().encode(Row(status: stage))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("\"\(stage.rawValue)\""), text)
        }
        XCTAssertEqual(RecordingStage.transcribedRaw.rawValue, "transcribed_raw")
        XCTAssertEqual(RecordingStage.summarized.rawValue, "summarized")
    }

    func testOneBadRowDoesNotSinkTheRestOfTheArray() throws {
        // Mirrors RecordingStore's element-by-element recovery path.
        let json = #"[{"status":"saved"},{"status":"???"},{"status":"recorded"}]"#
        let rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
        XCTAssertEqual(rows.map(\.status), [.saved, .recorded, .recorded])
    }

    // MARK: - Summary reconciliation (I9)

    func testRecapWrittenBeforeThisStageExistedIsPromoted() {
        // Otherwise the first launch after the update re-summarises the archive.
        XCTAssertEqual(
            SummaryStageReconciler.reconciled(current: .saved, hasRecapFile: true, hasMetadata: true),
            .summarized
        )
    }

    func testMeetingWithSummaryButNoMetadataIsNotDone() {
        // The 1.11 case: calendar-titled meetings got a recap and no topics.
        // Calling it `.summarized` would strand them — the worker skips terminal
        // stages, so the topics would never appear.
        XCTAssertNil(
            SummaryStageReconciler.reconciled(current: .saved, hasRecapFile: true, hasMetadata: false)
        )
        XCTAssertEqual(
            SummaryStageReconciler.reconciled(current: .summarized, hasRecapFile: true, hasMetadata: false),
            .saved
        )
    }

    func testRecapDeletedOutsideTheAppDowngrades() {
        XCTAssertEqual(
            SummaryStageReconciler.reconciled(current: .summarized, hasRecapFile: false, hasMetadata: true),
            .saved
        )
    }

    func testReconcilerLeavesEveryOtherStageAlone() {
        for stage in RecordingStage.allCases where stage != .saved && stage != .summarized {
            for hasRecap in [true, false] {
                XCTAssertNil(
                    SummaryStageReconciler.reconciled(
                        current: stage, hasRecapFile: hasRecap, hasMetadata: true
                    ),
                    "\(stage)"
                )
            }
        }
    }

    // MARK: - Order

    func testProgressOrderIsMonotonic() {
        XCTAssertEqual(
            RecordingStage.allCases.sorted(),
            [.recording, .recorded, .transcribing, .transcribedRaw, .transcribed, .saved, .summarized]
        )
    }

    // MARK: - Recap file matching

    func testRecapIsMatchedByIdNotByTitleSlug() {
        let id = "20260410_140029"
        // The slug in the filename goes stale the moment a meeting is renamed.
        XCTAssertTrue(RecapFile.isRecap("\(id)-staryj-zagolovok-recap.md", for: id))
        XCTAssertTrue(RecapFile.isRecap("\(id)--recap.md", for: id))
        XCTAssertFalse(RecapFile.isRecap("\(id)-planerka.md", for: id))
        XCTAssertFalse(RecapFile.isRecap("20260410_999999-x-recap.md", for: id))
    }

    func testTranscriptAndRecapNeverMatchTheSameFile() {
        let id = "20260410_140029"
        for name in ["\(id)-a.md", "\(id)-a-recap.md", "\(id)-recap.md"] {
            XCTAssertFalse(
                RecapFile.isRecap(name, for: id) && RecapFile.isTranscript(name, for: id),
                name
            )
        }
    }

    func testSummarizedIsTheOnlyTerminalStage() {
        // What `nextJob` filters on: everything below `summarized` still needs work.
        let needsWork = RecordingStage.allCases.filter { $0 > .recording && $0 < .summarized }
        XCTAssertEqual(needsWork, [.recorded, .transcribing, .transcribedRaw, .transcribed, .saved])
    }
}
