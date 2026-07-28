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
/// relaunch. Its presence takes the recording out of the queue until the user
/// explicitly retries — without that, an unfixable error (audio file deleted,
/// disk full) would be picked up forever.
public struct PipelineFailure: Codable, Equatable, Sendable {
    public let phase: String
    public let message: String
    public let at: Date

    public init(phase: PipelineActivity.Phase, message: String, at: Date = Date()) {
        self.phase = phase.rawValue
        self.message = message
        self.at = at
    }
}

// MARK: - Scheduling

/// Anything the worker can pick up. `RecordingEntry` conforms as-is.
public protocol PipelineCandidate {
    var id: String { get }
    var date: Date { get }
    var status: RecordingStage { get }
    var lastFailure: PipelineFailure? { get }
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

    public init(isRecording: Bool, inCall: Bool, isThermallyStressed: Bool) {
        self.isRecording = isRecording
        self.inCall = inCall
        self.isThermallyStressed = isThermallyStressed
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

/// The whole scheduler: the newest unfinished recording that isn't blocked.
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
/// The queue is never stored — it is derived from durable stages, so it
/// survives a crash for free and there is no second place to keep in sync.
public func nextJob(
    from candidates: [PipelineCandidate],
    policy: WorkerPolicy = .unrestricted
) -> PipelineJob? {
    guard policy.mayWork else { return nil }
    return candidates
        .filter { $0.lastFailure == nil && $0.status.nextPhase != nil }
        .max { $0.date < $1.date }
        .flatMap { candidate in
            candidate.status.nextPhase.map {
                PipelineJob(recordingID: candidate.id, phase: $0)
            }
        }
}
