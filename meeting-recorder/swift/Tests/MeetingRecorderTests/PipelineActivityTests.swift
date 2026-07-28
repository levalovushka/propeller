import XCTest
@testable import PropellerPure

/// Invariants I1, I2, I3, I5, I7 from docs/REFACTOR-PIPELINE-STATE.md.
/// These run without a disk, a model, or Zoom — the point of moving the
/// pipeline's decisions into pure functions.
final class PipelineActivityTests: XCTestCase {

    private struct Candidate: PipelineCandidate {
        let id: String
        let date: Date
        let status: RecordingStage
        var lastFailure: PipelineFailure?
    }

    private func candidate(
        _ id: String,
        _ status: RecordingStage,
        minutesAgo: Int,
        failed: Bool = false
    ) -> Candidate {
        Candidate(
            id: id,
            date: Date(timeIntervalSince1970: 10_000 - Double(minutesAgo) * 60),
            status: status,
            lastFailure: failed
                ? PipelineFailure(phase: .transcribing, message: "нет аудиофайла")
                : nil
        )
    }

    // MARK: - I1: idle carries no progress text

    func testIdleHasNoMessageAtAll() {
        XCTAssertNil(PipelineActivity.idle.message)
        // The old bug: a progress line set during work outlived the work itself.
        // Unrepresentable now — `.idle` has nowhere to keep one.
        XCTAssertTrue(PipelineActivity.idle.isIdle)
    }

    func testWorkingAlwaysHasAMessageEvenWithoutDetail() {
        for phase in PipelineActivity.Phase.allCases {
            let activity = PipelineActivity.working(recordingID: "a", phase: phase, detail: nil)
            XCTAssertEqual(activity.message, phase.defaultMessage, "\(phase)")
        }
    }

    func testSidecarDetailWinsOverTheDefaultLine() {
        let activity = PipelineActivity.working(
            recordingID: "a", phase: .transcribing, detail: "Чанк 2 из 5"
        )
        XCTAssertEqual(activity.message, "Чанк 2 из 5")
        // An empty detail must fall back, not blank the line.
        let empty = PipelineActivity.working(recordingID: "a", phase: .transcribing, detail: "")
        XCTAssertEqual(empty.message, PipelineActivity.Phase.transcribing.defaultMessage)
    }

    // MARK: - I2: exactly one recording spins

    func testActivityConcernsExactlyOneRecording() {
        let activity = PipelineActivity.working(recordingID: "A", phase: .saving, detail: nil)
        XCTAssertTrue(activity.concerns("A"))
        XCTAssertFalse(activity.concerns("B"))
        XCTAssertFalse(PipelineActivity.idle.concerns("A"))
    }

    // MARK: - I3: stages only move forward

    func testEveryPhaseAdvancesTheStage() {
        for stage in RecordingStage.allCases {
            guard let phase = stage.nextPhase else { continue }
            // `.transcribing` is the one stage that repairs in place: it is the
            // crash marker for a phase that never finished.
            if stage == .transcribing {
                XCTAssertGreaterThan(phase.completedStage, stage, "\(stage)")
                continue
            }
            XCTAssertGreaterThan(phase.completedStage, stage, "\(stage) → \(phase)")
        }
    }

    /// I3, the version that actually bit: re-running a phase on a finished
    /// meeting must not knock it back into the queue. Renaming a meeting
    /// rewrites its markdown — that must not cost a fresh summary.
    func testFinishingAPhaseNeverMovesAStageBackwards() {
        for stage in RecordingStage.allCases {
            for phase in PipelineActivity.Phase.allCases {
                XCTAssertGreaterThanOrEqual(
                    stage.advanced(to: phase.completedStage), stage,
                    "\(phase) pulled \(stage) backwards"
                )
            }
        }
    }

    func testResavingASummarisedMeetingKeepsItSummarised() {
        XCTAssertEqual(RecordingStage.summarized.advanced(to: .saved), .summarized)
        XCTAssertEqual(RecordingStage.transcribed.advanced(to: .saved), .saved)
    }

    func testASRLandsOnTheCheckpointNotOnTranscribed() {
        // I4 restated at the phase level: skipping to `.transcribed` would throw
        // away the diarization-resume path.
        XCTAssertEqual(PipelineActivity.Phase.transcribing.completedStage, .transcribedRaw)
    }

    func testTerminalStagesOweNothing() {
        XCTAssertNil(RecordingStage.summarized.nextPhase)
        XCTAssertNil(RecordingStage.recording.nextPhase)
    }

    // MARK: - I5: stopped recordings reach the queue

    func testStoppedRecordingIsPickedUp() {
        let job = nextJob(from: [candidate("A", .recorded, minutesAgo: 1)])
        XCTAssertEqual(job, PipelineJob(recordingID: "A", phase: .transcribing))
    }

    func testEveryNonTerminalStageEventuallyGetsAJob() {
        for stage in RecordingStage.allCases where stage != .recording && stage != .summarized {
            XCTAssertNotNil(
                nextJob(from: [candidate("A", stage, minutesAgo: 1)]),
                "\(stage) must be queued, not stranded"
            )
        }
    }

    /// The meeting that just ended must not queue behind a week of backlog —
    /// someone is sitting there waiting to read it.
    func testJustFinishedMeetingBeatsTheSummaryBacklog() {
        let job = nextJob(from: [
            candidate("backlog-1", .saved, minutesAgo: 10_000),
            candidate("backlog-2", .saved, minutesAgo: 9_000),
            candidate("just-stopped", .recorded, minutesAgo: 0),
        ])
        XCTAssertEqual(job?.recordingID, "just-stopped")
    }

    /// And it keeps that priority through every phase — including the summary,
    /// which is the part actually worth waiting for. Prioritising transcripts
    /// over summaries would drop it to the back of the queue right after
    /// `.saved`.
    func testTheFreshMeetingKeepsPriorityAllTheWayToItsSummary() {
        let backlog = candidate("backlog", .saved, minutesAgo: 10_000)
        for stage in [RecordingStage.recorded, .transcribedRaw, .transcribed, .saved] {
            let job = nextJob(from: [backlog, candidate("fresh", stage, minutesAgo: 0)])
            XCTAssertEqual(job?.recordingID, "fresh", "lost priority at \(stage)")
        }
    }

    func testBacklogIsWorkedNewestFirst() {
        let job = nextJob(from: [
            candidate("newer", .saved, minutesAgo: 100),
            candidate("older", .saved, minutesAgo: 900),
        ])
        XCTAssertEqual(job?.recordingID, "newer")
    }

    /// A `.saved` meeting is just one that still owes a summary — the backfill
    /// is not a separate subsystem any more.
    func testSummaryBackfillIsJustAnotherJob() {
        let job = nextJob(from: [candidate("A", .saved, minutesAgo: 5)])
        XCTAssertEqual(job, PipelineJob(recordingID: "A", phase: .summarizing))
    }

    // MARK: - I7: a failure is never retried on its own

    func testFailedRecordingIsSkippedForever() {
        let failed = candidate("A", .recorded, minutesAgo: 5, failed: true)
        XCTAssertNil(nextJob(from: [failed]))
        // Twice in a row — this is the loop that a missing audio file would spin.
        XCTAssertNil(nextJob(from: [failed]))
    }

    func testFailureBlocksOnlyItsOwnRecording() {
        let job = nextJob(from: [
            candidate("broken", .recorded, minutesAgo: 90, failed: true),
            candidate("fine", .recorded, minutesAgo: 5),
        ])
        XCTAssertEqual(job?.recordingID, "fine")
    }

    func testClearingTheFailureRequeues() {
        var entry = candidate("A", .recorded, minutesAgo: 5, failed: true)
        XCTAssertNil(nextJob(from: [entry]))
        entry.lastFailure = nil          // what the "Повторить" button does
        XCTAssertNotNil(nextJob(from: [entry]))
    }

    // MARK: - Worker policy

    func testWorkerStaysOffDuringRecordingCallOrHeat() {
        let queue = [candidate("A", .saved, minutesAgo: 5)]
        let blocking = [
            WorkerPolicy(isRecording: true, inCall: false, isThermallyStressed: false),
            WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false),
            WorkerPolicy(isRecording: false, inCall: false, isThermallyStressed: true),
        ]
        for policy in blocking {
            XCTAssertNil(nextJob(from: queue, policy: policy), "\(policy)")
        }
        XCTAssertNotNil(nextJob(from: queue, policy: .unrestricted))
    }

    func testNothingToDoOnAnEmptyOrFinishedArchive() {
        XCTAssertNil(nextJob(from: []))
        XCTAssertNil(nextJob(from: [candidate("A", .summarized, minutesAgo: 5)]))
    }
}
