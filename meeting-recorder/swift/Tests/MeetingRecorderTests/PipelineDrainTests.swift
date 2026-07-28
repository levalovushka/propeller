import XCTest
@testable import PropellerPure

/// The worker loop's rules, exercised without an ASR sidecar, an LLM or a disk.
/// This is the "start → stop → transcript → recap" scenario from
/// dogfood-checklist.md, run in microseconds against fake phases.
final class PipelineDrainTests: XCTestCase {

    /// Stand-in for the archive: stages advance, failures park a recording —
    /// the same rules `nextJob` reads in the real app.
    private final class FakeArchive {
        struct Row: PipelineCandidate {
            let id: String
            let date: Date
            var status: RecordingStage
            var lastFailure: PipelineFailure?
        }
        var rows: [Row]
        private(set) var performed: [PipelineJob] = []

        init(_ rows: [(String, RecordingStage)]) {
            self.rows = rows.enumerated().map { index, row in
                Row(
                    id: row.0,
                    date: Date(timeIntervalSince1970: Double(index)),
                    status: row.1,
                    lastFailure: nil
                )
            }
        }

        func next(policy: WorkerPolicy = .unrestricted) -> PipelineJob? {
            nextJob(from: rows, policy: policy)
        }

        /// A phase that behaves: it advances the stage it completed.
        func complete(_ job: PipelineJob) -> PhaseOutcome {
            performed.append(job)
            guard let i = rows.firstIndex(where: { $0.id == job.recordingID }) else { return .advanced }
            rows[i].status = rows[i].status.advanced(to: job.phase.completedStage)
            return .advanced
        }

        func fail(_ job: PipelineJob) -> PhaseOutcome {
            performed.append(job)
            guard let i = rows.firstIndex(where: { $0.id == job.recordingID }) else { return .advanced }
            rows[i].lastFailure = PipelineFailure(phase: job.phase, message: "нет аудиофайла")
            return .advanced
        }
    }

    // MARK: - The happy path

    func testDrainsOneMeetingAllTheWayToASummary() async {
        let archive = FakeArchive([("A", .recorded)])
        let stop = await PipelineDrain.run(
            nextJob: { archive.next() },
            perform: { archive.complete($0) },
            isCancelled: { false }
        )
        XCTAssertEqual(stop, .finished)
        XCTAssertEqual(
            archive.performed.map(\.phase),
            [.transcribing, .diarizing, .saving, .summarizing],
            "the whole pipeline should run off one stopped recording"
        )
        XCTAssertEqual(archive.rows[0].status, .summarized)
    }

    /// The regression the priority rule exists to prevent: a fresh meeting must
    /// reach its summary before the backlog gets any attention at all.
    func testFinishesTheFreshMeetingCompletelyBeforeTheBacklog() async {
        let archive = FakeArchive([("backlog", .saved), ("just-stopped", .recorded)])
        await PipelineDrain.run(
            nextJob: { archive.next() },
            perform: { archive.complete($0) },
            isCancelled: { false }
        )
        XCTAssertEqual(
            archive.performed.map(\.recordingID),
            ["just-stopped", "just-stopped", "just-stopped", "just-stopped", "backlog"]
        )
    }

    // MARK: - Stopping

    func testStopsWhenAPhaseReportsItCannotProceed() async {
        let archive = FakeArchive([("A", .saved)])
        let stop = await PipelineDrain.run(
            nextJob: { archive.next() },
            perform: { _ in .blocked },       // no summary provider installed
            isCancelled: { false }
        )
        XCTAssertEqual(stop, .blocked(PipelineJob(recordingID: "A", phase: .summarizing)))
        // Crucially not parked: once Ollama shows up, a kick picks it back up.
        XCTAssertNil(archive.rows[0].lastFailure)
    }

    func testStopsBetweenPhasesWhenCancelled() async {
        let archive = FakeArchive([("A", .recorded)])
        var passes = 0
        let stop = await PipelineDrain.run(
            nextJob: { archive.next() },
            perform: { archive.complete($0) },
            isCancelled: { passes += 1; return passes > 2 }
        )
        XCTAssertEqual(stop, .cancelled)
        XCTAssertEqual(archive.performed.count, 2, "a call started — no new phase should begin")
    }

    func testAFailedRecordingDoesNotBlockTheRest() async {
        let archive = FakeArchive([("broken", .recorded), ("fine", .recorded)])
        await PipelineDrain.run(
            nextJob: { archive.next() },
            perform: { job in
                job.recordingID == "broken" ? archive.fail(job) : archive.complete(job)
            },
            isCancelled: { false }
        )
        XCTAssertEqual(archive.rows[0].status, .recorded, "the broken one is parked where it was")
        XCTAssertEqual(archive.rows[1].status, .summarized)
    }

    // MARK: - The loop that would never end

    /// A phase that reports progress without making any is the one way this
    /// loop can hang the app: `nextJob` is derived from stages, so an unchanged
    /// stage yields the same job forever. Real cases exist — a recording
    /// deleted mid-flight makes a phase return early having touched nothing.
    func testAPhaseThatChangesNothingStopsTheDrain() async {
        let archive = FakeArchive([("A", .recorded)])
        var calls = 0
        let stop = await PipelineDrain.run(
            nextJob: { archive.next() },
            perform: { _ in calls += 1; return .advanced },   // does nothing
            isCancelled: { false }
        )
        XCTAssertEqual(stop, .stalled(PipelineJob(recordingID: "A", phase: .transcribing)))
        XCTAssertEqual(calls, 1, "must not retry a phase that made no progress")
    }

    func testWorkerStaysOffEntirelyDuringACall() async {
        let archive = FakeArchive([("A", .recorded)])
        let inCall = WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false)
        let stop = await PipelineDrain.run(
            nextJob: { archive.next(policy: inCall) },
            perform: { archive.complete($0) },
            isCancelled: { false }
        )
        XCTAssertEqual(stop, .finished)
        XCTAssertTrue(archive.performed.isEmpty)
    }
}
