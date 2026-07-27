import Foundation
import SwiftUI

// MARK: - Pipeline Step

enum PipelineStep: String {
    case pending, running, done, failed

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Recording Entry (persisted to recordings.json)

struct RecordingEntry: Identifiable, Codable {
    let id: String            // e.g. "20260410_140029"
    let filename: String      // e.g. "20260410_140029.wav"
    let date: Date
    var duration: Double      // seconds (preserved even after audio deletion)
    var title: String
    /// Status chain: recording → recorded → transcribing → transcribed_raw → transcribed → saved
    var status: String
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

// MARK: - Persisted Segment (codable, stored on RecordingEntry.mergedSegmentsJSON)

/// A single transcribed line with its speaker attribution and timing.
/// Stored on RecordingEntry so the user can reassign individual segments
/// to a different speaker label after the fact, including the case where
/// diarization merged two real participants into one "Speaker N" cluster.
///
/// `speaker` is the displayed name in the transcript ("Speaker 0", the
/// recording owner's name, or a manually typed name).
struct PersistedSegment: Codable, Identifiable {
    var id: Int { index }
    /// Stable index used as identity in the segment list.
    let index: Int
    var startTime: Double
    var endTime: Double
    var text: String
    var speaker: String
}
