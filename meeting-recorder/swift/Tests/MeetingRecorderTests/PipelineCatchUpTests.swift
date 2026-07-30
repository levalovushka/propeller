import XCTest
@testable import PropellerPure

/// The scenarios where the app has to catch up on its own, run against the real
/// scheduler and the real worker loop.
///
/// The bar for every test here is the same: **the user never had to do
/// anything, and never saw a failure.** A meeting recorded while the summary
/// model was still downloading, three meetings stopped back to back, a call
/// that starts mid-summary, a laptop that sleeps in the middle — all of them
/// end with a finished archive.
final class PipelineCatchUpTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The archive, plus the two things that make it a queue: stages advance and
    /// failures carry their own retry plan.
    private final class Archive {
        struct Row: PipelineCandidate {
            let id: String
            let date: Date
            var status: RecordingStage
            var lastFailure: PipelineFailure?
            var audioAvailable = true
        }
        var rows: [Row]
        var now: Date
        var policy: WorkerPolicy = .unrestricted
        var requested: String?
        private(set) var performed: [PipelineJob] = []

        init(_ rows: [(String, RecordingStage)], now: Date) {
            self.now = now
            self.rows = rows.enumerated().map { index, row in
                // Index order = age order: the last row is the newest meeting.
                Row(
                    id: row.0,
                    date: now.addingTimeInterval(Double(index) * 60 - 86_400),
                    status: row.1
                )
            }
        }

        var outlook: PipelineOutlook {
            pipelineOutlook(from: rows, policy: policy, now: now, preferring: requested)
        }

        func index(_ id: String) -> Int? { rows.firstIndex { $0.id == id } }

        /// A phase that works.
        func complete(_ job: PipelineJob) -> PhaseOutcome {
            performed.append(job)
            guard let i = index(job.recordingID) else { return .advanced }
            rows[i].status = rows[i].status.advanced(to: job.phase.completedStage)
            rows[i].lastFailure = nil
            return .advanced
        }

        /// A phase that fails the way the world fails.
        func fail(_ job: PipelineJob, _ message: String) -> PhaseOutcome {
            performed.append(job)
            guard let i = index(job.recordingID) else { return .advanced }
            rows[i].lastFailure = PipelineFailure(
                phase: job.phase, message: message, at: now, previous: rows[i].lastFailure
            )
            return .advanced
        }

        /// Drains until the queue stops handing out work, exactly as `AppState`
        /// does — including recomputing the outlook every pass.
        @discardableResult
        func drain(_ perform: (PipelineJob) -> PhaseOutcome) async -> PipelineDrain.Stop {
            await PipelineDrain.run(
                nextJob: { self.outlook.job },
                perform: { perform($0) },
                isCancelled: { false }
            )
        }
    }

    // MARK: - The model arrived late

    /// The one that started all of this: a meeting recorded before the summary
    /// model finished downloading. The transcript lands, the summary cannot, and
    /// the meeting must not be marked broken — it is waiting, and the moment the
    /// model appears it finishes with nobody being asked.
    func testAMeetingRecordedBeforeTheModelWasReadyFinishesWhenItArrives() async {
        let archive = Archive([("call", .recorded)], now: t0)
        var modelReady = false

        let stop = await archive.drain { job in
            if job.phase == .summarizing && !modelReady { return .blocked }
            return archive.complete(job)
        }
        XCTAssertEqual(stop, .blocked(PipelineJob(recordingID: "call", phase: .summarizing)))
        XCTAssertEqual(archive.rows[0].status, .saved)
        XCTAssertNil(archive.rows[0].lastFailure, "waiting for a model is not this meeting's fault")
        XCTAssertEqual(archive.outlook.owed, 1, "still owed, so the app keeps checking")

        modelReady = true
        await archive.drain { archive.complete($0) }
        XCTAssertEqual(archive.rows[0].status, .summarized)
    }

    /// Summaries turned off is a different thing from a model that has not
    /// arrived: there is nothing to wait for, so the archive is *finished* and
    /// nothing wakes up to check on it.
    func testWithSummariesOffAnArchiveOfTranscriptsIsFinished() async {
        let archive = Archive([("a", .recorded), ("b", .saved)], now: t0)
        archive.policy = WorkerPolicy(
            isRecording: false, inCall: false, isThermallyStressed: false, summariesEnabled: false
        )
        await archive.drain { archive.complete($0) }

        XCTAssertEqual(archive.rows.map(\.status), [.saved, .saved])
        XCTAssertEqual(archive.outlook.owed, 0)
        XCTAssertNil(archive.outlook.wakeAt, "nothing owed means no timers at all")

        // Turned back on, the backlog is owed again — without anyone re-recording.
        archive.policy = .unrestricted
        XCTAssertEqual(archive.outlook.owed, 2)
        await archive.drain { archive.complete($0) }
        XCTAssertEqual(archive.rows.map(\.status), [.summarized, .summarized])
    }

    // MARK: - The network fell over

    /// A summary that fails on a dropped connection is retried on a backoff and
    /// nothing is shown. This is the difference between "silently no summary"
    /// and "the app dealt with it".
    func testADroppedConnectionIsRetriedWithoutTellingAnyone() async {
        let archive = Archive([("call", .saved)], now: t0)
        var failuresLeft = 2

        await archive.drain { job in
            if failuresLeft > 0 {
                failuresLeft -= 1
                return archive.fail(job, "The network connection was lost")
            }
            return archive.complete(job)
        }
        // First failure: parked *until a deadline*, not for good.
        let failure = archive.rows[0].lastFailure
        XCTAssertNotNil(failure)
        XCTAssertFalse(failure?.needsAttention ?? true, "nothing to tell the user yet")
        XCTAssertNil(archive.outlook.job, "and nothing to do this second")
        XCTAssertEqual(archive.outlook.wakeAt, t0.addingTimeInterval(20))

        // The clock reaches the deadline — the meeting is back in the queue.
        archive.now = t0.addingTimeInterval(20)
        await archive.drain { job in
            if failuresLeft > 0 {
                failuresLeft -= 1
                return archive.fail(job, "The network connection was lost")
            }
            return archive.complete(job)
        }
        XCTAssertEqual(archive.outlook.wakeAt, archive.now.addingTimeInterval(60), "second backoff")

        archive.now = archive.now.addingTimeInterval(60)
        await archive.drain { archive.complete($0) }
        XCTAssertEqual(archive.rows[0].status, .summarized)
        XCTAssertNil(archive.rows[0].lastFailure, "a success clears the history")
    }

    /// The other half of the promise: when it really is broken, the user is told
    /// — once, after the app has genuinely tried.
    func testAProviderThatNeverComesBackEventuallyBecomesTheUsersProblem() async {
        let archive = Archive([("call", .saved)], now: t0)
        var attempts = 0

        for _ in 0..<10 {
            await archive.drain { job in
                attempts += 1
                return archive.fail(job, "Ollama недоступен")
            }
            // Jump to whatever deadline the app set for itself, if any.
            guard let wake = archive.outlook.wakeAt else { break }
            archive.now = wake
        }
        XCTAssertEqual(attempts, PipelineRetry.maxAttempts(for: .summarizing))
        XCTAssertTrue(archive.rows[0].lastFailure?.needsAttention ?? false)
        XCTAssertEqual(archive.outlook.owed, 0, "parked meetings do not keep timers alive")
        XCTAssertNil(archive.outlook.wakeAt)
    }

    /// A deleted audio file is hopeless on the first try — there is no point
    /// spending three ASR passes discovering that.
    func testAMissingAudioFileIsNotRetried() async {
        let archive = Archive([("gone", .recorded)], now: t0)
        var attempts = 0
        await archive.drain { job in
            attempts += 1
            return archive.fail(job, "Аудиофайл не найден — нельзя расшифровать.")
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(archive.rows[0].lastFailure?.needsAttention ?? false)
    }

    /// And a meeting whose audio the *user* deleted owes nothing at all — no
    /// failure, no button, no retry. It is an archived transcript, not a fault.
    func testAMeetingWhoseAudioTheUserDeletedIsNotAFailure() async {
        let archive = Archive([("archived", .recorded)], now: t0)
        archive.rows[0].audioAvailable = false

        let stop = await archive.drain { archive.complete($0) }
        XCTAssertEqual(stop, .finished)
        XCTAssertTrue(archive.performed.isEmpty)
        XCTAssertEqual(archive.outlook.owed, 0)
        XCTAssertNil(archive.rows[0].lastFailure)

        // A transcript already on disk still gets its summary — audio is only
        // needed by the two phases that read it.
        archive.rows[0].status = .transcribed
        await archive.drain { archive.complete($0) }
        XCTAssertEqual(archive.rows[0].status, .summarized)
    }

    // MARK: - Several meetings at once

    /// Three meetings stopped in a row (back-to-back calls, or a launch after a
    /// week away). Every one of them ends finished, newest first, and one
    /// failure in the middle does not hold up the rest.
    func testABacklogDrainsCompletelyNewestFirst() async {
        let archive = Archive([("mon", .recorded), ("tue", .saved), ("wed", .recorded)], now: t0)
        await archive.drain { job in
            job.recordingID == "tue"
                ? archive.fail(job, "Аудиофайл не найден")   // permanent, skipped
                : archive.complete(job)
        }
        XCTAssertEqual(
            archive.performed.filter { $0.phase == .transcribing }.map(\.recordingID),
            ["wed", "mon"],
            "the freshest meeting is transcribed first"
        )
        XCTAssertEqual(archive.rows.map(\.status), [.summarized, .saved, .summarized])
        XCTAssertEqual(archive.outlook.owed, 0)
    }

    /// A meeting the user asked for by hand jumps the queue: they are looking at
    /// that row, and recency is a guess about what they want, not a fact.
    func testAMeetingTheUserAskedForGoesFirst() {
        let archive = Archive([("old", .saved), ("fresh", .recorded)], now: t0)
        XCTAssertEqual(archive.outlook.job?.recordingID, "fresh")
        archive.requested = "old"
        XCTAssertEqual(archive.outlook.job?.recordingID, "old")
    }

    func testAHandRequestStopsMatteringOnceThatMeetingIsDone() async {
        let archive = Archive([("old", .saved), ("fresh", .recorded)], now: t0)
        archive.requested = "old"
        await archive.drain { archive.complete($0) }
        XCTAssertEqual(archive.performed.first?.recordingID, "old")
        XCTAssertEqual(archive.rows.map(\.status), [.summarized, .summarized])
    }

    // MARK: - The Mac had other plans

    /// A call starts while the backlog is being summarised. The worker stops,
    /// the meeting is *not* marked failed, and when the call ends it picks up
    /// exactly where it was.
    func testACallInterruptsTheBacklogAndItResumesAfterwards() async {
        let archive = Archive([("backlog", .transcribed)], now: t0)
        archive.policy = WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false)

        XCTAssertNil(archive.outlook.job)
        XCTAssertTrue(archive.outlook.pausedByPolicy, "owed work, just not now")
        XCTAssertEqual(archive.outlook.owed, 1)
        XCTAssertNil(archive.outlook.wakeAt, "a call ending is an event, not a deadline")

        archive.policy = .unrestricted
        await archive.drain { archive.complete($0) }
        XCTAssertEqual(archive.rows[0].status, .summarized)
        XCTAssertNil(archive.rows[0].lastFailure)
    }

    func testAHotMacPausesTheQueueWithoutBreakingAnything() {
        let archive = Archive([("backlog", .saved)], now: t0)
        archive.policy = WorkerPolicy(isRecording: false, inCall: false, isThermallyStressed: true)
        XCTAssertNil(archive.outlook.job)
        XCTAssertTrue(archive.outlook.pausedByPolicy)
        archive.policy = .unrestricted
        XCTAssertNotNil(archive.outlook.job)
    }

    /// A laptop closed for the weekend with a retry pending: the deadline is an
    /// absolute moment, so on wake it is simply overdue and runs at once. (A
    /// timer would have slept through it — `Timer` stops counting while the
    /// machine does.)
    func testARetryDeadlineSurvivesTheMacGoingToSleep() async {
        let archive = Archive([("call", .saved)], now: t0)
        await archive.drain { archive.fail($0, "Ollama недоступен") }
        XCTAssertNil(archive.outlook.job)

        archive.now = t0.addingTimeInterval(3 * 86_400)      // Monday morning
        XCTAssertNotNil(archive.outlook.job, "an overdue retry runs immediately")
        await archive.drain { archive.complete($0) }
        XCTAssertEqual(archive.rows[0].status, .summarized)
    }

    // MARK: - Nothing to do

    func testAFinishedArchiveWantsNoTimersAndNoWork() {
        let archive = Archive([("a", .summarized), ("b", .summarized)], now: t0)
        XCTAssertEqual(archive.outlook, .nothingToDo)
    }

    func testARecordingInProgressIsNotWork() {
        let archive = Archive([("live", .recording)], now: t0)
        XCTAssertEqual(archive.outlook, .nothingToDo)
    }
}
