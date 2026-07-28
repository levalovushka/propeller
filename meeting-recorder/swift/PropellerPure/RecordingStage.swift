import Foundation

/// How far a recording has progressed. Persisted in `recordings.json` under the
/// key `status`, so the raw values are the strings that shipped before this
/// enum existed — an older build reads a newer index and vice versa.
///
/// This is the *durable* half of pipeline state: what has been achieved, not
/// what is running. In-flight work lives in `PipelineActivity`.
public enum RecordingStage: String, Codable, CaseIterable, Sendable {
    case recording      = "recording"
    /// Audio on disk, ASR never ran.
    case recorded       = "recorded"
    /// Only reachable by crashing mid-ASR; `RecordingRecovery` resolves it on
    /// launch. Kept as a case so a crashed index decodes losslessly.
    case transcribing   = "transcribing"
    /// ASR done, diarization not — the checkpoint that saves an hour of GPU.
    case transcribedRaw = "transcribed_raw"
    case transcribed    = "transcribed"
    /// Transcript markdown written.
    case saved          = "saved"
    /// Summary + metadata done. Nothing left for the pipeline to do.
    case summarized     = "summarized"

    /// Unknown strings decode to `.recorded` rather than throwing: a value we
    /// don't recognise must never cost the user their archive. `.recorded` is
    /// the safe floor — the pipeline can always re-derive everything from audio.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecordingStage(rawValue: raw) ?? .recorded
    }
}

/// Naming of the summary markdown written next to the transcript. The filename
/// embeds a slug of the title, which can go stale after a rename — so a
/// recording is matched by its id prefix and the `-recap.md` suffix, never by
/// reconstructing the expected name.
public enum RecapFile {
    public static let suffix = "-recap.md"

    public static func isRecap(_ filename: String, for recordingID: String) -> Bool {
        filename.hasPrefix(recordingID + "-") && filename.hasSuffix(suffix)
    }

    /// A transcript markdown for the same recording — same prefix, no suffix.
    public static func isTranscript(_ filename: String, for recordingID: String) -> Bool {
        filename.hasPrefix(recordingID + "-")
            && filename.hasSuffix(".md")
            && !filename.hasSuffix(suffix)
    }
}

extension RecordingStage {
    /// Stage after finishing a phase. Never moves backwards (I3).
    ///
    /// A phase re-run on an already-finished meeting — re-saving markdown after
    /// a speaker relabel, say — must not knock it back to `.saved` and hand it
    /// to the worker for a fresh summary. Going backwards is something only an
    /// explicit user action does, and it says so at the call site.
    public func advanced(to reached: RecordingStage) -> RecordingStage {
        Swift.max(self, reached)
    }
}

/// Keeps `.summarized` honest against what is actually on disk.
///
/// `.summarized` means *recap **and** metadata* — a 1.11 meeting that got a
/// summary but no topics is not done, and marking it done would strand it: the
/// worker skips terminal stages, so its topics would never be generated.
public enum SummaryStageReconciler {
    /// New stage, or nil when the current one is already right.
    public static func reconciled(
        current: RecordingStage,
        hasRecapFile: Bool,
        hasMetadata: Bool
    ) -> RecordingStage? {
        let done = hasRecapFile && hasMetadata
        switch (current, done) {
        case (.saved, true):       return .summarized
        // Either the recap was deleted outside the app, or metadata never ran.
        case (.summarized, false): return .saved
        default:                   return nil
        }
    }
}

extension RecordingStage: Comparable {
    /// Progress order. `transcribing` sits where it interrupts, between
    /// `recorded` and the ASR checkpoint.
    private var rank: Int {
        switch self {
        case .recording:      return 0
        case .recorded:       return 1
        case .transcribing:   return 2
        case .transcribedRaw: return 3
        case .transcribed:    return 4
        case .saved:          return 5
        case .summarized:     return 6
        }
    }

    public static func < (lhs: RecordingStage, rhs: RecordingStage) -> Bool {
        lhs.rank < rhs.rank
    }
}
