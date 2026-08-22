import Foundation

/// # Retry policy for the provisioning funnel — engine and summary model
///
/// The pipeline's retry rules (`PipelineRetry`) are attached to a recording:
/// the failure lives in `entry.lastFailure` and is encoded on disk. Provisioning
/// has no recording to attach to — the obligation is «нет LLM» is not a legal
/// state for the app (`design/principles.md` §10, `no-dead-ends.md` §5) — so it
/// gets its own machine, with two deliberate differences:
///
/// 1. **Failure classes are measured, not read from an error string.** The
///    incident this file exists because of (2026-08-22) produced an error whose
///    text lived for milliseconds inside an NDJSON stream and was never seen by
///    anyone. Duration and progress are facts the caller always has; the string
///    is a witness that may not show up.
/// 2. **Signals reset the ladder.** A blind ladder burned six attempts in the
///    eighteen minutes the network happened to be dead, then went quiet for the
///    hour in which it came back. Whoever observes the world change (network
///    path restored, machine woke) tells the ladder, and the next attempt is
///    immediate.
///
/// Deliberately without jitter, same argument as `PipelineRetry`: one client,
/// and randomness would only make the behaviour untestable.
public enum ProvisioningRetry {

    // MARK: - Failure classes

    /// What kind of failure this was — decided from measurements the attempt
    /// itself produced, never from matching the error text.
    ///
    /// `instant` and `stall` are different diseases with different cures even
    /// though both end in «модели нет»: an instant death means the far side is
    /// answering (with a refusal at the transport level — TLS interception, a
    /// closed port), a stall means packets leave and nothing returns (the
    /// blackhole shape of RU ISP blocking). Telemetry needs them apart to tell
    /// us which one the field actually has.
    public enum FailureClass: String, Sendable, CaseIterable {
        /// Died before `instantThreshold` without a single progress line.
        case instant
        /// No progress for `stallThreshold`, connection formally alive.
        case stall
        /// A definitive «no» that no amount of waiting or network changes: only
        /// a call site that *saw* such an answer may declare it — never timing,
        /// and never an error line from the local daemon. The daemon proxies
        /// the registry, so its error lines report somebody else's transport
        /// («dial tcp … no such host» arrives exactly this way) and are
        /// classified by measurement like any transport death. Misfiling one
        /// here is the expensive direction: `refused` is the class the network
        /// signal deliberately leaves alone.
        case refused
        /// No room for the payload. Declared by the call site that measured
        /// the disk. Time does not cure it, which is why the network signal
        /// leaves it alone.
        case disk
        /// Failed some other way. Retried all the same — the ladder has no
        /// case that gives up (§10: the counter is the hidden retry button).
        case other
    }

    /// An attempt that dies faster than this without progress never reached a
    /// working transport. Below any plausible time-to-first-byte for a 3.4 GB
    /// pull; above any local refusal (the incident's refusals took ~900 ms).
    public static let instantThreshold: TimeInterval = 5

    /// No progress for this long means the transfer is dead even if the socket
    /// is not: the previous backstop was the URLSession idle timeout of an
    /// hour, which is a timeout only in name. Three minutes is long enough for
    /// a registry to think between blobs and short enough that a person who
    /// checks the settings twice sees a moving number, not the same frozen one.
    public static let stallThreshold: TimeInterval = 180

    /// The pull watchdog's question, kept next to the classifier so both sides
    /// of «what counts as stalled» are one number.
    public static func shouldAbort(sinceLastProgress: TimeInterval) -> Bool {
        sinceLastProgress >= stallThreshold
    }

    /// Classify a failed attempt from what was measured about it.
    ///
    /// `sinceLastProgress` is time since the last progress line — when no
    /// progress ever arrived, the caller passes the attempt's whole duration.
    /// `refused` and `disk` are not reachable from here: they are claims about
    /// a response body and a disk respectively, and only the call site that
    /// looked at those may declare them (§10, the same rule as terminals in
    /// the pipeline).
    public static func transportClass(
        duration: TimeInterval,
        sinceLastProgress: TimeInterval,
        sawProgress: Bool
    ) -> FailureClass {
        if shouldAbort(sinceLastProgress: sinceLastProgress) { return .stall }
        if !sawProgress && duration < instantThreshold { return .instant }
        return .other
    }

    // MARK: - Ladder

    /// Backoff between attempts: 20 s, 1 min, 5 min, 20 min, then an hour —
    /// and an hour from then on, without end.
    ///
    /// **There is no last step.** A count of attempts belongs to a request
    /// somebody is waiting on with a dialogue open; this is a background
    /// obligation. The previous, finite ladder (`pullRetryDelays`, ~17 minutes
    /// total) is how the app came to be silent for exactly the hour in which
    /// the tester's network came back.
    ///
    /// The pipeline's ladder, by construction: one backoff policy in the app,
    /// tuned in one place. What differs between the two machines is everything
    /// else — classes, signals — never the pacing.
    public static let steps: [TimeInterval] = PipelineRetry.steps

    /// How soon to look again when an attempt was declined because recording
    /// or transcription is running (`ModelProvisioning.decide` →
    /// `.waitForQuiet`). This is the deadline that keeps «busy» from becoming
    /// a dead end: the one-shot ladder timer is consumed whether or not the
    /// attempt ran, and the end of a recording is not a provisioning signal —
    /// without a recheck the vigil would depend on somebody clicking the app.
    /// Two minutes: cheap (the check is a couple of field reads), and no
    /// meeting ends in less.
    public static let busyRecheck: TimeInterval = 120

    // MARK: - Signals

    /// The world changed in a way that may have changed the answer. Observed by
    /// whoever can see it (an `NWPathMonitor`, the wake notification); the
    /// ladder only decides whether the change is relevant to its last failure.
    public enum Signal: String, Sendable, CaseIterable {
        /// The network path became satisfied after not being so.
        case networkPathRestored
        /// The machine woke from sleep or the app became active. Cheap to act
        /// on and correlated with everything a laptop's environment can change
        /// (network, VPN, disk), so it resets every class.
        case wokeOrActivated
    }

    /// Does this signal earn the class an immediate fresh start?
    ///
    /// The network coming back says nothing about a full disk, and nothing
    /// about a server that looked at the request and said no — those two keep
    /// walking their ladder. Everything transport-shaped resets: the network
    /// is the thing that was broken.
    public static func resets(_ signal: Signal, class failureClass: FailureClass) -> Bool {
        switch signal {
        case .wokeOrActivated:
            return true
        case .networkPathRestored:
            switch failureClass {
            case .instant, .stall, .other: return true
            case .refused, .disk:          return false
            }
        }
    }
}

/// The edge detector for the network signal: fires exactly on the transition
/// from a broken path to a working one.
///
/// Pure and separate from the `NWPathMonitor` that feeds it, for two reasons.
/// The rule itself («the first callback is a baseline, not news; only
/// false→true is a restore») is decidable without a network and must be
/// testable — treating the baseline as a restore would turn the signal into
/// the timer §10 forbids. And the detector must be advanced *on the monitor's
/// own serial queue*: hopping every raw update to the main actor in its own
/// `Task` loses ordering — a down→up pair observed as up→down misses the
/// restore entirely. Mutate here, hop only when this returns true.
public struct NetworkRestoreEdge: Equatable, Sendable {
    private var wasSatisfied: Bool?

    public init() {}

    /// Feed one path update; true means the network just came back.
    public mutating func observe(satisfied: Bool) -> Bool {
        defer { wasSatisfied = satisfied }
        return wasSatisfied == false && satisfied
    }
}

/// What counts as a pull still moving — the watchdog's other half.
///
/// A pull line carries a status and, during transfers, a byte counter. The
/// counter restarts at zero for every blob, so «bytes grew» is wrong twice: a
/// blob following a bigger one reads as three silent minutes and gets a live
/// download killed. Liveness is any *change* in the pair — the wedged-transfer
/// signature this exists to catch is the same line repeating verbatim.
public struct PullLiveness: Equatable, Sendable {
    private var lastStatus = ""
    private var lastCompleted: Double?

    public init() {}

    /// Feed one pull line; true means the pull moved and the watchdog's clock
    /// restarts.
    public mutating func advanced(status: String, completed: Double?) -> Bool {
        var moved = false
        if !status.isEmpty, status != lastStatus {
            lastStatus = status
            moved = true
        }
        if completed != lastCompleted {
            lastCompleted = completed
            // `completed` going *down* is a new blob starting, not time
            // flowing backwards — progress either way.
            if completed != nil { moved = true }
        }
        return moved
    }
}

/// The one piece of state the funnel keeps between attempts. A struct so the
/// owner (`AppState`) holds exactly one and tests can drive it without a clock.
public struct ProvisioningLadder: Equatable, Sendable {

    /// Attempts since the last success or reset. Never encoded to disk: a
    /// relaunch starting from a clean ladder is correct, not a bug — launch is
    /// itself a wake signal.
    public private(set) var attempt = 0

    /// What the last failure was, kept so a signal can ask whether it is the
    /// kind of change that cures that failure.
    public private(set) var lastClass: ProvisioningRetry.FailureClass?

    public init() {}

    /// Record a failure and answer when to try again. Returns a date, not an
    /// optional: provisioning has no terminal case, so there is always a next
    /// attempt — the type holds §10's promise.
    public mutating func failed(
        _ failureClass: ProvisioningRetry.FailureClass,
        at now: Date
    ) -> Date {
        attempt += 1
        lastClass = failureClass
        let steps = ProvisioningRetry.steps
        return now.addingTimeInterval(steps[min(attempt - 1, steps.count - 1)])
    }

    /// The world changed. True means the ladder reset and the owner should
    /// attempt now instead of waiting out the current step; false means the
    /// signal is irrelevant to what failed (or nothing has failed).
    public mutating func signal(_ signal: ProvisioningRetry.Signal) -> Bool {
        guard attempt > 0, let last = lastClass,
              ProvisioningRetry.resets(signal, class: last) else { return false }
        attempt = 0
        lastClass = nil
        return true
    }

    /// The obligation was delivered; the ladder owes nothing.
    public mutating func succeeded() {
        attempt = 0
        lastClass = nil
    }
}
