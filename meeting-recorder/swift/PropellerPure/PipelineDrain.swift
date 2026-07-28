import Foundation

/// The worker loop, with the app pulled out of it.
///
/// `AppState` supplies three closures — what to do next, how to do it, and
/// whether we've been cancelled — and this decides how the loop behaves. That
/// makes the loop's rules (stop on `blocked`, stop on cancel, never spin)
/// testable without an ASR sidecar, an LLM, or a disk.
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
}
