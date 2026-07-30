import Foundation
import PropellerPure
import SwiftUI

// MARK: - Recording Entry (persisted to recordings.json)

struct RecordingEntry: Identifiable, Codable {
    let id: String            // e.g. "20260410_140029"
    let filename: String      // e.g. "20260410_140029.wav"
    let date: Date
    var duration: Double      // seconds (preserved even after audio deletion)
    var title: String
    /// How far the pipeline has taken this recording. Persisted; the in-flight
    /// half of the state lives in `AppState`, not here.
    var status: RecordingStage
    var transcript: String?
    var notes: String?
    var language: String?     // ISO code ("da", "en") or nil = use default
    /// JSON-serialized [ASRSegment] array, stored after the ASR pass
    /// completes. Allows diarization to resume after a crash without re-running ASR.
    /// Backward-compatible: old recordings without this field decode as nil.
    var rawSegmentsJSON: String?
    /// JSON-serialized [PersistedSegment] saved after diarization completes.
    /// Powers per-segment speaker reassignment in the detail view (the
    /// transcript text alone is lossy — once you rename a speaker globally
    /// you can't tell which segments came from which detected cluster).
    /// Cleared when the user manually edits the transcript text, since the
    /// segment timestamps and labels can no longer be trusted to match.
    /// Backward-compatible: old recordings without this field decode as nil.
    var mergedSegmentsJSON: String?
    /// Short list of discussed topics, LLM-derived from the finished summary.
    /// Rendered as the meeting's subtitle in the Meetings list. nil for old records.
    var topics: [String]?
    /// Meeting-type tags, LLM-classified from the approved `MeetingTags.vocabulary`.
    /// Values outside the vocabulary are discarded before storing. nil for old records.
    var tags: [String]?
    /// True once the user manually renamed the meeting. Blocks LLM/calendar
    /// auto-title from overwriting a human-chosen title. nil/false = eligible.
    var titleManuallySet: Bool?
    /// True when this recording finished without a usable system-audio stem.
    /// Per-entry (not a global latch) so the badge doesn't stick on other meetings.
    var micOnlyCaptured: Bool?
    /// False when system audio was captured from the whole machine instead of
    /// the meeting app — music and notifications are in the stem too. Recorded
    /// so «how often does the app-scoped filter actually survive» is answerable
    /// from the archive rather than by guessing. nil = not recorded (pre-1.14).
    var systemCaptureAppScoped: Bool?
    /// Where the system stem starts on this recording's timeline, in seconds of
    /// microphone audio (`StemTimeline`). Measured during capture, persisted so a
    /// re-mix after a crash lands the far end in the same place. nil = never
    /// measured (mic-only, or recorded before 1.14) — treated as zero, which is
    /// what every build before this one did.
    var systemStemOffset: Double?
    /// Last pipeline failure for *this* recording. Per-entry so work on another
    /// meeting can't erase it, and persisted so it survives a relaunch. While
    /// set, the worker skips this recording; "Повторить" clears it.
    var lastFailure: PipelineFailure?

    /// Topics joined for subtitle display ("Ретро, ресурсы команды, планирование").
    var subtitleText: String { (topics ?? []).joined(separator: ", ") }

    var dateFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    var durationFormatted: String {
        let s = Int(duration)
        let m = s / 60
        let sec = s % 60
        if m > 0 { return "\(m)m \(String(format: "%02d", sec))s" }
        return "\(sec)s"
    }

    var audioFileExists: Bool {
        let path = (Preferences.shared.recordingsPath as NSString)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: path)
    }

    var fileSizeBytes: Int64? {
        let path = (Preferences.shared.recordingsPath as NSString)
            .appendingPathComponent(filename)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    var fileSizeFormatted: String {
        guard let size = fileSizeBytes else { return "" }
        if size > 1_000_000 { return "\(size / 1_000_000) MB" }
        if size > 1_000 { return "\(size / 1_000) KB" }
        return "\(size) B"
    }
}

/// Everything the scheduler needs is already here — `id`, `date`, `status`,
/// `lastFailure` — so the queue is a pure function over the archive.
extension RecordingEntry: PipelineCandidate {
    /// Deliberately spelled out rather than left to the protocol's `true`
    /// default: a meeting whose audio the user deleted owes no ASR, and the
    /// scheduler is the only place that can know that without inventing a
    /// failure for it. Costs one `stat`, and only for the two stages that could
    /// still need audio.
    var audioAvailable: Bool { audioFileExists }

    /// The pipeline has run out of its own options on this meeting, so the UI
    /// may offer a button. A meeting merely waiting out a retry is *not* this:
    /// showing it would turn the catch-up the user is not supposed to notice
    /// into an error they have to think about.
    var needsAttention: Bool { lastFailure?.needsAttention == true }
}

// MARK: - Meeting tag vocabulary

/// Approved meeting-type tag vocabulary (v1, 2026-07-22). The LLM classifies each
/// meeting into 0..N of these; any value outside the set is discarded on parse.
/// Multi-label by design (a call can be both "клиентская" and "защита решения").
enum MeetingTags {
    static let vocabulary: [String] = [
        "1:1", "стендап", "ретро", "планирование", "дизайн-синк", "дискавери",
        "брейншторм", "стратегия", "клиентская", "защита решения", "найм",
        "админ", "внутренняя",
    ]
}
