import Foundation

/// Who a failure belongs to, and therefore what happens next.
///
/// Three cases, and **none of them is "ask the user"** — that is the whole point
/// (`design/no-dead-ends.md`). A missing model, a sidecar mid-spawn, a laptop
/// that slept: the world was briefly wrong, so wait and try again. A 413 from our
/// own chunker or a phase that claimed progress and made none: our bug, so try
/// again *and* tell ourselves through telemetry. Audio the user deleted, a
/// recording with no speech in it: nothing to do, ever, by anyone — a result, not
/// an error.
///
/// The old two-case version had `permanent`, which meant "parked until someone
/// finds the retry button". There is no button any more, and archives written by
/// those builds migrate through `PipelineFailure.init(from:)`.
public enum FailureKind: String, Codable, Sendable, CaseIterable {
    /// The world was briefly wrong. Retried on a backoff, silently, forever.
    case transient
    /// Ours. Retried the same way — and counted, because a bug that only shows up
    /// on someone else's machine is one we never hear about otherwise.
    case ourFault = "our_fault"
    /// Nothing further is possible: the input is gone or was never there. The one
    /// kind that owes no more work, and the only legitimate end of the line.
    case terminal

    /// Does the worker owe this recording another attempt?
    public var isRetryable: Bool { self != .terminal }
}

/// How often the worker tries again, and how it decides whether to.
///
/// Deliberately without jitter. Jitter exists to desynchronise many clients
/// hitting one server (AWS, "Exponential Backoff and Jitter"); here there is
/// one client and a server on loopback, so randomness would only make the
/// behaviour untestable.
public enum PipelineRetry {

    /// Backoff between attempts: 20 s, 1 min, 5 min, 20 min, then an hour — and
    /// an hour from then on, without end.
    ///
    /// The first step is short because the overwhelming majority of real failures
    /// here are "not up yet" — `ollama serve` still loading, the ASR sidecar
    /// mid-spawn, a model being written to disk. The tail is long because anything
    /// that survives that is an environment problem, and hammering it costs
    /// battery for nothing.
    ///
    /// **There is no last step.** A count of attempts belongs to a request
    /// somebody is waiting on with a dialogue open; this is a background
    /// obligation, and the moment it gives up, a person has to be told and asked
    /// to press something. That was the single largest source of dead ends in the
    /// app: not the failures, the counter.
    public static let steps: [TimeInterval] = [20, 60, 300, 1200, 3600]

    /// When the worker tries this phase again — nil only for a terminal failure,
    /// because that is the only case where there is nothing left to try.
    public static func nextAttempt(
        kind: FailureKind,
        attempt: Int,
        phase: PipelineActivity.Phase,
        after now: Date
    ) -> Date? {
        guard kind.isRetryable else { return nil }
        let step = steps[min(max(attempt, 1) - 1, steps.count - 1)]
        return now.addingTimeInterval(step)
    }

    /// How long to wait before asking again whether a summary provider showed
    /// up, given how many drains in a row have ended blocked on it.
    ///
    /// The question itself is cheap — a file check, or one request to a server
    /// that is already running — but a user who has decided not to install a
    /// model should not pay for it every minute forever, so the interval walks
    /// out to half an hour and stays there.
    public static func providerRecheck(afterBlockedStreak streak: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [60, 300, 900, 1800]
        return ladder[min(max(streak, 1) - 1, ladder.count - 1)]
    }

    // MARK: - Classification

    /// Read a failure message and decide whose problem it is.
    ///
    /// Text matching, because that is what the pipeline actually has: most of
    /// these errors arrive as `localizedDescription` from a sidecar, URLSession
    /// or Foundation.
    ///
    /// **This function never returns `.terminal`.** A terminal is a claim about
    /// the *input* — the audio is gone, there was no speech — and no error string
    /// is good enough evidence for that. "gigastt недоступен — файл не найден" is
    /// a broken install, not a missing recording, and parking a meeting forever on
    /// a substring match is exactly the kind of dead end this file now exists to
    /// prevent. Terminals are declared by the call site that checked the input
    /// itself, and only there.
    public static func classify(_ message: String) -> FailureKind {
        let text = message.lowercased()
        for marker in ourFaultMarkers where text.contains(marker) { return .ourFault }
        // Everything else — known transient markers *and* unknowns — waits and
        // tries again. There is no longer a cost to being wrong about an unknown:
        // the ladder walks out to an hour and nobody is told either way.
        return .transient
    }

    /// Ours, and knowable from the message alone. Data, not code, so a new case is
    /// one string and one test.
    static let ourFaultMarkers: [String] = [
        // The request can never fit as built: the chunker miscounted. Retrying is
        // still right (Э4 makes the retry divide the chunk instead of repeating
        // it), and the signal goes to telemetry rather than to a person.
        "413", "too large", "слишком велик", "слишком больш",
        // A reasoning model that spent the whole window thinking will spend it
        // again on the next identical call — our prompt handling, not the weather.
        "ушла в рассуждения",
    ]

    static let transientMarkers: [String] = [
        "недоступен", "unavailable", "не запущен", "not running",
        "timed out", "timeout", "таймаут", "не успело", "перегружен",
        "connection", "соединени", "network", "сеть", "offline", "офлайн",
        "socket", "broken pipe", "eof", "cannot connect", "could not connect",
        "не удалось подключиться", "temporarily", "busy", "занят",
        "408", "429", "500", "502", "503", "504",
    ]
}
