import XCTest
@testable import PropellerPure

/// The one promise the whole catch-up rests on: **owed work always has a way
/// back.** Either something is running, or there is a deadline to wake at, or
/// the pipeline is waiting on an event that is actually observed (a call ending,
/// a stopped recording, a Mac that cooled down).
///
/// Every stranded-meeting bug this app has had was a hole in exactly that
/// sentence, so it is checked here as a property over randomised archives rather
/// than as a handful of examples.
final class PipelineNeverStrandsWorkTests: XCTestCase {

    private struct Row: PipelineCandidate {
        let id: String
        let date: Date
        var status: RecordingStage
        var lastFailure: PipelineFailure?
        var audioAvailable: Bool
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Deterministic pseudo-random archives — a fixed seed, so a failure here is
    /// reproducible instead of a story about a build that went red once.
    private func archives(count: Int) -> [[Row]] {
        var seed: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let stages = RecordingStage.allCases
        let messages = [
            "Ollama недоступен",                        // transient
            "Аудиофайл не найден — нельзя расшифровать.", // permanent
        ]
        return (0..<count).map { _ in
            (0..<next(6)).map { i in
                let failure: PipelineFailure? = {
                    switch next(3) {
                    case 0: return nil
                    default:
                        var f = PipelineFailure(
                            phase: PipelineActivity.Phase.allCases[next(4)],
                            message: messages[next(2)],
                            at: t0.addingTimeInterval(-Double(next(600)))
                        )
                        // Sometimes escalate it a few times, to reach the
                        // attempts-exhausted shape too.
                        for _ in 0..<next(6) {
                            f = PipelineFailure(
                                phase: PipelineActivity.Phase(rawValue: f.phase) ?? .summarizing,
                                message: f.message, at: f.at, previous: f
                            )
                        }
                        return f
                    }
                }()
                return Row(
                    id: "r\(i)",
                    date: t0.addingTimeInterval(-Double(next(100_000))),
                    status: stages[next(stages.count)],
                    lastFailure: failure,
                    audioAvailable: next(4) > 0
                )
            }
        }
    }

    private var policies: [WorkerPolicy] {
        [
            .unrestricted,
            WorkerPolicy(isRecording: true, inCall: false, isThermallyStressed: false),
            WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false),
            WorkerPolicy(isRecording: false, inCall: false, isThermallyStressed: true),
            WorkerPolicy(
                isRecording: false, inCall: false, isThermallyStressed: false,
                summariesEnabled: false
            ),
        ]
    }

    // MARK: - The property

    func testOwedWorkAlwaysHasAWayBack() {
        for archive in archives(count: 400) {
            for policy in policies {
                let outlook = pipelineOutlook(from: archive, policy: policy, now: t0)
                guard outlook.owed > 0 else { continue }
                XCTAssertTrue(
                    outlook.job != nil || outlook.wakeAt != nil || outlook.pausedByPolicy,
                    """
                    \(outlook.owed) meeting(s) owed with nothing running, no deadline \
                    and no policy waiting on an event — that archive would sit \
                    unfinished until the next launch. policy: \(policy)
                    """
                )
            }
        }
    }

    /// And the same after a drain stops, which is the moment the app decides
    /// whether to set a timer at all.
    func testAfterEveryDrainStopOwedWorkStillHasAWayBack() {
        let job = PipelineJob(recordingID: "r0", phase: .summarizing)
        let stops: [PipelineDrain.Stop] = [.finished, .blocked(job), .cancelled, .stalled(job)]
        for archive in archives(count: 200) {
            for policy in policies {
                let outlook = pipelineOutlook(from: archive, policy: policy, now: t0)
                for stop in stops {
                    let plan = PipelineDrain.plan(
                        after: stop, outlook: outlook, blockedStreak: 0, now: t0
                    )
                    guard outlook.owed > 0 else { continue }
                    // `.stalled` parks the offending job; anything else owed must
                    // still be reachable.
                    if case .stalled = stop, outlook.owed == 1 { continue }
                    XCTAssertTrue(
                        plan.wakeAt != nil || outlook.job != nil,
                        "\(stop) left \(outlook.owed) owed with no deadline"
                    )
                }
            }
        }
    }

    /// The mirror image, and just as important for the battery: a finished
    /// archive must not keep a timer alive.
    func testAFinishedArchiveSchedulesNothing() {
        let done = [
            Row(id: "a", date: t0, status: .summarized, lastFailure: nil, audioAvailable: true),
            Row(id: "b", date: t0, status: .recording, lastFailure: nil, audioAvailable: true),
        ]
        let outlook = pipelineOutlook(from: done, policy: .unrestricted, now: t0)
        XCTAssertEqual(outlook, .nothingToDo)
        for stop in [PipelineDrain.Stop.finished, .cancelled] {
            let plan = PipelineDrain.plan(after: stop, outlook: outlook, blockedStreak: 0, now: t0)
            XCTAssertNil(plan.wakeAt, "\(stop) scheduled a wakeup for an empty queue")
        }
    }

    /// A meeting parked for the user is not owed — otherwise a single broken
    /// meeting would keep the app waking up about it forever.
    func testAMeetingParkedForTheUserKeepsNoTimers() {
        var failure = PipelineFailure(phase: .summarizing, message: "Ollama недоступен", at: t0)
        while !failure.needsAttention {
            failure = PipelineFailure(
                phase: .summarizing, message: "Ollama недоступен", at: t0, previous: failure
            )
        }
        let archive = [Row(id: "a", date: t0, status: .saved, lastFailure: failure, audioAvailable: true)]
        let outlook = pipelineOutlook(from: archive, policy: .unrestricted, now: t0)
        XCTAssertEqual(outlook, .nothingToDo)
    }

    // MARK: - The provider ladder

    func testBlockedOnAProviderAlwaysSchedulesAnotherLook() {
        let archive = [Row(id: "a", date: t0, status: .saved, lastFailure: nil, audioAvailable: true)]
        let outlook = pipelineOutlook(from: archive, policy: .unrestricted, now: t0)
        var streak = 0
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            let plan = PipelineDrain.plan(
                after: .blocked(PipelineJob(recordingID: "a", phase: .summarizing)),
                outlook: outlook, blockedStreak: streak, now: t0
            )
            streak = plan.blockedStreak
            waits.append(plan.wakeAt!.timeIntervalSince(t0))
        }
        XCTAssertEqual(waits, [60, 300, 900, 1800, 1800])
        XCTAssertEqual(streak, 5)
    }

    /// A retry deadline that comes sooner than the next provider check wins —
    /// waiting half an hour to retry something due in 20 seconds would be the
    /// ladder making things worse.
    func testTheSoonerOfTheTwoDeadlinesWins() {
        let archive = [
            Row(id: "a", date: t0, status: .saved, lastFailure: nil, audioAvailable: true),
            Row(id: "b", date: t0.addingTimeInterval(-60), status: .saved,
                lastFailure: PipelineFailure(phase: .summarizing, message: "HTTP 503", at: t0),
                audioAvailable: true),
        ]
        let outlook = pipelineOutlook(from: archive, policy: .unrestricted, now: t0)
        let plan = PipelineDrain.plan(
            after: .blocked(PipelineJob(recordingID: "a", phase: .summarizing)),
            outlook: outlook, blockedStreak: 3, now: t0
        )
        XCTAssertEqual(
            plan.wakeAt, t0.addingTimeInterval(20),
            "a retry due in 20s must not wait out the half-hour provider ladder"
        )
    }

    func testAFinishedDrainForgetsTheProviderLadder() {
        let plan = PipelineDrain.plan(
            after: .finished, outlook: .nothingToDo, blockedStreak: 4, now: t0
        )
        XCTAssertEqual(plan.blockedStreak, 0)
    }

    func testAPausedDrainKeepsTheLadderWhereItWas() {
        let plan = PipelineDrain.plan(
            after: .cancelled, outlook: .nothingToDo, blockedStreak: 2, now: t0
        )
        XCTAssertEqual(plan.blockedStreak, 2, "a call is not evidence about the provider")
    }

    /// A pause waits on an event — a call ending, a Mac cooling down — but not
    /// only on one. If that notification never arrives the archive still gets
    /// looked at, minutes later rather than never.
    func testAPolicyPauseStillGetsADeadline() {
        let archive = [Row(id: "a", date: t0, status: .saved, lastFailure: nil, audioAvailable: true)]
        let inCall = WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false)
        let outlook = pipelineOutlook(from: archive, policy: inCall, now: t0)
        XCTAssertTrue(outlook.pausedByPolicy)
        let plan = PipelineDrain.plan(after: .finished, outlook: outlook, blockedStreak: 0, now: t0)
        XCTAssertEqual(plan.wakeAt, t0.addingTimeInterval(PipelineDrain.policyRecheck))
    }

    // MARK: - How much work a summary actually is

    func testSummaryWorkAndTheStageReconcilerAgree() {
        for hasRecap in [true, false] {
            for hasMetadata in [true, false] {
                let work = SummaryWork.needed(hasRecapFile: hasRecap, hasMetadata: hasMetadata)
                let reconciled = SummaryStageReconciler.reconciled(
                    current: .saved, hasRecapFile: hasRecap, hasMetadata: hasMetadata
                )
                XCTAssertEqual(
                    work == .nothing, reconciled == .summarized,
                    "recap: \(hasRecap), metadata: \(hasMetadata) — the reconciler and the "
                        + "phase disagree about whether this meeting is done"
                )
            }
        }
    }

    /// The expensive mistake this replaced: an archive of summaries missing their
    /// topics was re-summarised from scratch, meeting by meeting.
    func testAMeetingWithASummaryButNoTopicsOnlyNeedsTheShortPass() {
        XCTAssertEqual(
            SummaryWork.needed(hasRecapFile: true, hasMetadata: false), .metadataOnly
        )
        XCTAssertEqual(
            SummaryWork.needed(hasRecapFile: false, hasMetadata: false), .fullRecap
        )
    }
}
