import Foundation

/// What the pipeline is doing *right now* — the ephemeral half of the state
/// that `RecordingStage` records durably.
///
/// One value for the whole app, because there is one worker (see `nextJob`).
/// There is deliberately no `.failed` case: a failure belongs to the recording
/// it happened to, not to the app, or starting work on B would erase the error
/// on A. Failures live in `PipelineFailure` on the entry.
public enum PipelineActivity: Equatable {
    case idle
    case working(recordingID: String, phase: Phase, detail: String?)

    public enum Phase: String, Equatable, CaseIterable, Sendable {
        case transcribing, diarizing, saving, summarizing
    }

    /// Whether this recording is the one being worked on. The only question the
    /// UI ever needs — replaces every hand-written `busyRecordingID == entry.id`.
    public func concerns(_ recordingID: String) -> Bool {
        guard case .working(let id, _, _) = self else { return false }
        return id == recordingID
    }

    public var isIdle: Bool { self == .idle }

    /// Progress line. Derived from the phase, never stored — an idle pipeline
    /// has no text to show stale, which is invariant I1 by construction.
    public var message: String? {
        guard case .working(_, let phase, let detail) = self else { return nil }
        if let detail, !detail.isEmpty { return detail }
        return phase.defaultMessage
    }
}

extension PipelineActivity.Phase {
    public var defaultMessage: String {
        switch self {
        case .transcribing: return "Расшифровываем…"
        case .diarizing:    return "Определяем спикеров…"
        case .saving:       return "Сохраняем…"
        case .summarizing:  return "Генерируем саммари…"
        }
    }

    /// Stage reached when this phase completes.
    public var completedStage: RecordingStage {
        switch self {
        // ASR lands on the checkpoint, not on `.transcribed` — losing this
        // distinction costs an hour of GPU work on the next crash (I4).
        case .transcribing: return .transcribedRaw
        case .diarizing:    return .transcribed
        case .saving:       return .saved
        case .summarizing:  return .summarized
        }
    }
}

/// A pipeline failure, kept on the recording so it survives other work and a
/// relaunch.
///
/// A failure carries its own recovery plan. `kind` says whether waiting could
/// possibly help, `attempt` counts how many tries this phase has had, and
/// `nextAttemptAt` is the moment the worker may try again by itself — nil when
/// it may not, which is the only case a person is ever shown.
///
/// The distinction is the whole point. Every failure used to park a meeting
/// until someone found the retry button, so an `ollama serve` that was half a
/// second late, or a laptop that slept mid-summary, left a meeting unfinished
/// with a red button on it. Unfinishable failures (audio deleted, disk full)
/// still park immediately — retrying them forever is the other way to be wrong.
public struct PipelineFailure: Codable, Equatable, Sendable {
    public let phase: String
    public let message: String
    public let at: Date
    /// Consecutive failures of this phase on this recording, first one = 1.
    public let attempt: Int
    public let kind: FailureKind
    /// When the worker may try again unprompted. Nil = never; the user is the
    /// only way forward from here.
    public let nextAttemptAt: Date?

    /// Records a failure and schedules its own next attempt.
    ///
    /// - Parameters:
    ///   - previous: the failure this one replaces, so attempts accumulate
    ///     across retries instead of resetting to 1 forever.
    ///   - kind: pass when the call site knows better than the message text.
    public init(
        phase: PipelineActivity.Phase,
        message: String,
        at: Date = Date(),
        previous: PipelineFailure? = nil,
        kind: FailureKind? = nil
    ) {
        let resolved = kind ?? PipelineRetry.classify(message)
        // Only a repeat of the *same* phase escalates: a meeting that failed ASR
        // last week and fails its summary today is on its first summary attempt.
        let repeats = previous?.phase == phase.rawValue ? (previous?.attempt ?? 0) : 0
        let attempt = repeats + 1
        self.phase = phase.rawValue
        self.message = message
        self.at = at
        self.attempt = attempt
        self.kind = resolved
        self.nextAttemptAt = PipelineRetry.nextAttempt(
            kind: resolved, attempt: attempt, phase: phase, after: at
        )
    }

    /// Nothing more happens on its own. The one failure state worth a button,
    /// a toast or a notification — everything else the app is still handling.
    public var needsAttention: Bool { nextAttemptAt == nil }

    /// Waiting out a backoff: owed work, just not yet.
    public func isWaiting(at now: Date) -> Bool {
        guard let due = nextAttemptAt else { return false }
        return due > now
    }

    /// Whether this failure keeps the recording out of the queue right now.
    public func blocks(at now: Date) -> Bool { needsAttention || isWaiting(at: now) }

    /// Indexes written before failures carried a recovery plan decode as
    /// parked-for-the-user — exactly how that build behaved. An old archive must
    /// never wake up and re-run ASR on a meeting the user already gave up on.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(String.self, forKey: .phase)
        message = try c.decode(String.self, forKey: .message)
        at = try c.decode(Date.self, forKey: .at)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 1
        kind = try c.decodeIfPresent(FailureKind.self, forKey: .kind) ?? .permanent
        nextAttemptAt = try c.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
    }
}

// MARK: - Scheduling

/// Anything the worker can pick up. `RecordingEntry` conforms as-is.
public protocol PipelineCandidate {
    var id: String { get }
    var date: Date { get }
    var status: RecordingStage { get }
    var lastFailure: PipelineFailure? { get }
    /// False when the audio is gone — deleted by the user to reclaim space, or
    /// never written. ASR and diarization then have no input, so the meeting
    /// owes nothing rather than owing a failure nobody can fix.
    var audioAvailable: Bool { get }
}

extension PipelineCandidate {
    /// Meetings whose audio is beside the point (already transcribed, or a test
    /// fixture) don't have to say so.
    public var audioAvailable: Bool { true }
}

public struct PipelineJob: Equatable, Sendable {
    public let recordingID: String
    public let phase: PipelineActivity.Phase

    public init(recordingID: String, phase: PipelineActivity.Phase) {
        self.recordingID = recordingID
        self.phase = phase
    }
}

/// When the worker is allowed to run at all. These guards used to be scattered
/// across the summary backfill only, which is why ASR could still fire in the
/// middle of a call.
public struct WorkerPolicy: Equatable, Sendable {
    public let isRecording: Bool
    public let inCall: Bool
    public let isThermallyStressed: Bool
    /// False when the user turned summaries off. Not a gate on the worker — it
    /// removes the summary phase from what a meeting owes, so an archive of
    /// transcripts is *finished* rather than permanently one phase short. A gate
    /// would leave every meeting queued, waking timers forever for work that is
    /// never going to run.
    public let summariesEnabled: Bool

    public init(
        isRecording: Bool,
        inCall: Bool,
        isThermallyStressed: Bool,
        summariesEnabled: Bool = true
    ) {
        self.isRecording = isRecording
        self.inCall = inCall
        self.isThermallyStressed = isThermallyStressed
        self.summariesEnabled = summariesEnabled
    }

    public var mayWork: Bool { !isRecording && !inCall && !isThermallyStressed }

    public static let unrestricted = WorkerPolicy(
        isRecording: false, inCall: false, isThermallyStressed: false
    )
}

extension RecordingStage {
    /// The phase that moves this stage forward, or nil when nothing is owed.
    public var nextPhase: PipelineActivity.Phase? {
        switch self {
        case .recording, .summarized: return nil
        case .recorded:               return .transcribing
        // Only seen if recovery hasn't run yet; treat as "ASR still owed".
        case .transcribing:           return .transcribing
        case .transcribedRaw:         return .diarizing
        case .transcribed:            return .saving
        case .saved:                  return .summarizing
        }
    }
}

extension PipelineActivity.Phase {
    /// Phases that read the recording's audio. The two that do are the two that
    /// cannot run once it has been deleted.
    public var needsAudio: Bool {
        switch self {
        case .transcribing, .diarizing: return true
        case .saving, .summarizing:     return false
        }
    }
}

extension PipelineCandidate {
    /// The phase this recording owes, accounting for what is even possible: no
    /// audio means no ASR, summaries off means no summary.
    public func owedPhase(summariesEnabled: Bool) -> PipelineActivity.Phase? {
        guard let phase = status.nextPhase else { return nil }
        if phase.needsAudio && !audioAvailable { return nil }
        if phase == .summarizing && !summariesEnabled { return nil }
        return phase
    }
}

/// Everything the worker needs to decide what to do and when to look again.
///
/// One value instead of a bare "job or nil", because "nil" used to mean four
/// different things — nothing owed, waiting out a retry, paused by a call, or
/// blocked on heat — and the app could only respond to all four the same way:
/// stop, and hope something kicks it later. Half of them then never got a kick.
public struct PipelineOutlook: Equatable, Sendable {
    /// What to run right now.
    public let job: PipelineJob?
    /// Recordings the worker still intends to finish, now or later. Zero means
    /// the archive is genuinely done and no timer needs to exist.
    public let owed: Int
    /// The earliest moment a job could appear with no outside help — a retry
    /// deadline. Nil when only an event (a provider, a cooler Mac, a finished
    /// call) can change the answer.
    public let wakeAt: Date?
    /// Work is owed and runnable, but the policy says not now.
    public let pausedByPolicy: Bool

    public init(job: PipelineJob?, owed: Int, wakeAt: Date?, pausedByPolicy: Bool) {
        self.job = job
        self.owed = owed
        self.wakeAt = wakeAt
        self.pausedByPolicy = pausedByPolicy
    }

    public static let nothingToDo = PipelineOutlook(
        job: nil, owed: 0, wakeAt: nil, pausedByPolicy: false
    )
}

/// The whole scheduler.
///
/// **Newest first**, and it matters. The obvious oldest-first queue parks the
/// meeting that ended a minute ago behind a week of backlog — invisible on a
/// two-item archive, glaring once someone spends a week away from the app and
/// comes back with twenty meetings owed summaries.
///
/// Prioritising by stage instead (transcripts before summaries) only half-fixes
/// it: the fresh meeting gets its transcript quickly, then drops to the back of
/// the queue for its summary, which is the part the user is waiting to read.
/// One rule beats two tiers here — carry the newest meeting all the way to a
/// summary, then work backwards through the backlog.
///
/// The exception is `preferring`: a recording the user just asked for by hand.
/// They are looking at that row, so it outranks recency for as long as it owes
/// anything.
///
/// The queue is never stored — it is derived from durable stages, so it
/// survives a crash for free and there is no second place to keep in sync.
public func pipelineOutlook(
    from candidates: [PipelineCandidate],
    policy: WorkerPolicy = .unrestricted,
    now: Date = Date(),
    preferring requestedID: String? = nil
) -> PipelineOutlook {
    var owed = 0
    var wakeAt: Date?
    var best: (id: String, date: Date, phase: PipelineActivity.Phase, requested: Bool)?

    for candidate in candidates {
        guard let phase = candidate.owedPhase(summariesEnabled: policy.summariesEnabled) else {
            continue
        }
        if let failure = candidate.lastFailure {
            // Parked for the user: not owed, because nobody is going to pick it
            // up until they say so.
            if failure.needsAttention { continue }
            if failure.isWaiting(at: now) {
                owed += 1
                if let due = failure.nextAttemptAt {
                    wakeAt = wakeAt.map { Swift.min($0, due) } ?? due
                }
                continue
            }
        }
        owed += 1
        let requested = candidate.id == requestedID
        let wins: Bool = {
            guard let current = best else { return true }
            if requested != current.requested { return requested }
            return candidate.date > current.date
        }()
        if wins {
            best = (candidate.id, candidate.date, phase, requested)
        }
    }

    let runnable = best.map { PipelineJob(recordingID: $0.id, phase: $0.phase) }
    return PipelineOutlook(
        job: policy.mayWork ? runnable : nil,
        owed: owed,
        wakeAt: wakeAt,
        pausedByPolicy: !policy.mayWork && runnable != nil
    )
}

/// The next job, or nil. Thin wrapper over `pipelineOutlook` for the callers
/// that only need the answer and not the reason.
public func nextJob(
    from candidates: [PipelineCandidate],
    policy: WorkerPolicy = .unrestricted,
    now: Date = Date(),
    preferring requestedID: String? = nil
) -> PipelineJob? {
    pipelineOutlook(from: candidates, policy: policy, now: now, preferring: requestedID).job
}
