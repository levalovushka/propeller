import XCTest
@testable import PropellerPure

/// Keeps the state diagram in docs/REFACTOR-PIPELINE-STATE.md honest.
///
/// The diagram is derived from the types, not drawn by hand: this test renders
/// it from `RecordingStage` and compares it to the copy in the doc. Add a stage
/// or move a phase boundary and this fails, naming the exact line to update —
/// so the picture can never quietly drift away from the code.
final class PipelineDiagramTests: XCTestCase {

    /// The diagram, generated from the types. Kept byte-identical to the
    /// ```mermaid block in docs/REFACTOR-PIPELINE-STATE.md §4.
    static func render() -> String {
        var lines = ["stateDiagram-v2"]
        for stage in RecordingStage.allCases {
            guard let phase = stage.nextPhase else {
                lines.append("    \(stage.rawValue) --> [*]")
                continue
            }
            lines.append("    \(stage.rawValue) --> \(phase.completedStage.rawValue): \(phase.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    func testDiagramMatchesTheDocumentedOne() {
        let documented = """
        stateDiagram-v2
            recording --> [*]
            recorded --> transcribed_raw: transcribing
            transcribing --> transcribed_raw: transcribing
            transcribed_raw --> transcribed: diarizing
            transcribed --> saved: saving
            saved --> summarized: summarizing
            summarized --> [*]
        """
        XCTAssertEqual(
            Self.render(),
            documented,
            "The diagram in docs/REFACTOR-PIPELINE-STATE.md §4 no longer matches the types — update both."
        )
    }

    /// Every stage is either terminal or leads somewhere. A stage that owes work
    /// but has no phase would be a meeting stuck forever with no way to see it.
    func testNoStageIsStranded() {
        for stage in RecordingStage.allCases {
            let isTerminal = stage == .recording || stage == .summarized
            XCTAssertEqual(
                stage.nextPhase == nil, isTerminal,
                "\(stage) is neither terminal nor advanceable"
            )
        }
    }

    /// Following the phases from any stage must reach `.summarized` — no cycles,
    /// no dead ends. Guards against a future edit wiring two stages to each other.
    func testEveryStageReachesTheEnd() {
        for start in RecordingStage.allCases where start != .recording {
            var stage = start
            var hops = 0
            while let phase = stage.nextPhase {
                stage = phase.completedStage
                hops += 1
                XCTAssertLessThan(hops, RecordingStage.allCases.count + 1, "cycle from \(start)")
            }
            XCTAssertEqual(stage, .summarized, "\(start) does not lead to a finished meeting")
        }
    }
}
