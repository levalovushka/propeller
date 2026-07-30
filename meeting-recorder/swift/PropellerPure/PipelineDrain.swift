import Foundation

/// Outcome of one phase, as far as the loop is concerned.
public enum PhaseOutcome: Equatable, Sendable {
    /// The stage moved, or the recording was parked with a failure — either way
    /// there is something new to do next. Keep draining.
    case advanced
    /// Nothing is wrong with this recording; the pipeline itself cannot proceed
    /// (no summary provider yet). Stop until something kicks us again, or the
    /// loop would spin on the same meeting forever.
    case blocked
}

/// The worker loop, with the app pulled out of it.
///
/// `AppState` supplies three closures — what to do next, how to do it, and
/// whether we've been cancelled — and this decides how the loop behaves. That
/// makes the loop's rules (stop on `blocked`, stop on cancel, never spin, and
/// what to do once it stops) testable without an ASR sidecar, an LLM, or a disk.
public enum PipelineDrain {

    /// Why the drain stopped. Reported so a stall is visible instead of silent.
    public enum Stop: Equatable {
        /// Nothing left to do.
        case finished
        /// A phase reported it cannot proceed (no summary provider yet).
        case blocked(PipelineJob)
        case cancelled
        /// The same job came back after being run — the phase claimed progress
        /// but moved nothing, so running it again would loop forever.
        case stalled(PipelineJob)
    }

    /// Runs jobs until there are none, something blocks, or we're cancelled.
    ///
    /// - Parameters:
    ///   - nextJob: recomputed every pass — the queue is derived from stages,
    ///     so finishing one job is what produces the next.
    ///   - perform: runs one phase.
    ///   - isCancelled: checked between phases (a phase in flight is not
    ///     interrupted here; that is the caller's `Task` to cancel).
    @discardableResult
    public static func run(
        nextJob: () -> PipelineJob?,
        perform: (PipelineJob) async -> PhaseOutcome,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) async -> Stop {
        var previous: PipelineJob?
        while !isCancelled() {
            guard let job = nextJob() else { return .finished }
            // A phase that returns `.advanced` must have moved the stage or
            // parked the recording. If neither happened we would ask for the
            // same job forever — bail out loudly instead.
            if job == previous { return .stalled(job) }
            previous = job
            if await perform(job) == .blocked { return .blocked(job) }
        }
        return .cancelled
    }

    /// What to do once the drain stops.
    ///
    /// Pure, because this is the decision that used to be missing entirely: every
    /// branch ended with "stop and hope something kicks us later", and for three
    /// of the four there was nothing that ever would. A meeting could sit at
    /// `.saved` forever because the Mac was hot when the drain ran.
    ///
    /// The guarantee it exists to keep: **owed work always has a way back** — a
    /// deadline to wake at, every time, even when an observed event was supposed
    /// to provide one.
    ///
    /// Re-check interval for a policy pause. The events that end one (a call
    /// ending, a recording stopping, a Mac cooling down) are all observed, so
    /// this is belt and braces: a missed notification should cost a few minutes,
    /// not the archive.
    public static let policyRecheck: TimeInterval = 300

    public static func plan(
        after stop: Stop,
        outlook: PipelineOutlook,
        blockedStreak: Int,
        now: Date = Date()
    ) -> DrainPlan {
        // A policy pause always gets a deadline, so "owed work always has a way
        // back" holds without depending on a notification arriving.
        let paused = outlook.pausedByPolicy
            ? now.addingTimeInterval(policyRecheck)
            : nil
        let deadline = earlier(outlook.wakeAt, paused)
        switch stop {
        case .finished:
            // Either everything is done, or what is left is waiting out a retry
            // or a policy. Any provider trouble is over — reset the ladder.
            return DrainPlan(wakeAt: deadline, blockedStreak: 0, parkStalled: nil)
        case .blocked:
            // No provider to summarise with. Not the meeting's fault, so nothing
            // is parked; ask again on a ladder that walks out to half an hour.
            let streak = blockedStreak + 1
            let recheck = now.addingTimeInterval(
                PipelineRetry.providerRecheck(afterBlockedStreak: streak)
            )
            return DrainPlan(
                wakeAt: earlier(deadline, recheck),
                blockedStreak: streak,
                parkStalled: nil
            )
        case .cancelled:
            // Paused for a call, or superseded by an edit. Both end in an event —
            // but a deadline is still scheduled, because a pause whose event never
            // arrives must not strand the archive.
            return DrainPlan(
                wakeAt: deadline, blockedStreak: blockedStreak, parkStalled: nil
            )
        case .stalled(let job):
            // A phase claimed progress and made none. Parked, so an invisible
            // spin becomes a visible retry button.
            return DrainPlan(
                wakeAt: deadline, blockedStreak: blockedStreak, parkStalled: job
            )
        }
    }

    private static func earlier(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (let a?, let b?): return Swift.min(a, b)
        default:               return a ?? b
        }
    }
}

/// The worker's instructions after a drain: when to look again, where the
/// provider ladder stands, and whether a job has to be parked.
public struct DrainPlan: Equatable, Sendable {
    public let wakeAt: Date?
    public let blockedStreak: Int
    public let parkStalled: PipelineJob?

    public init(wakeAt: Date?, blockedStreak: Int, parkStalled: PipelineJob?) {
        self.wakeAt = wakeAt
        self.blockedStreak = blockedStreak
        self.parkStalled = parkStalled
    }
}
