import Foundation
import PropellerPure

/// The two places the pipeline leaves the app: speech recognition and the
/// summary model. Everything else it touches is our own code or the filesystem.
///
/// They exist so those boundaries can be swapped for fixtures — a run of the
/// scenarios in `dogfood-checklist.md` should not need a real 40-minute Zoom
/// call, a GPU, or a 3.4 GB model download. `AppState` takes both by init, so a
/// harness can hand it doubles while the app hands it the real thing.
///
/// Deliberately narrow: these are the calls the pipeline makes, not everything
/// the services can do. Setup, model downloads and sidecar lifecycle stay
/// concrete — they are configuration, not pipeline steps.

@MainActor
protocol Transcriber: AnyObject {
    func transcribeAudio(
        audioURL: URL,
        languageOverride: String?,
        progressCallback: ((String) -> Void)?,
        downloadProgress: ((Double) -> Void)?
    ) async throws -> RawTranscriptionResult

    func diarize(
        audioURL: URL,
        asrSegments: [ASRSegment],
        progressCallback: ((String) -> Void)?
    ) async throws -> MeetingTranscriptionResult

    /// Frees ASR/diarizer memory between jobs.
    func releaseHeavyResources()

    /// Re-assign speakers from mic vs system stem energy, or nil when the stems
    /// aren't usable. Not part of the queue — invoked from «Уточнить спикеров».
    func relabelSegmentsFromStems(audioURL: URL, segments: [PersistedSegment]) -> [PersistedSegment]?
}

protocol RecapBackend: Sendable {
    func generateRecap(
        title: String,
        transcriptMarkdown: String,
        transcriptPath: String,
        notes: String?,
        speakers: [String],
        duration: TimeInterval,
        recordingID: String,
        prefs: RecapPreferences
    ) async throws -> Result<RecapResult, RecapSkipReason>

    func generateMetadata(
        summaryMarkdown: String,
        needTitle: Bool,
        prefs: RecapPreferences
    ) async -> RecapService.RecapMetadata?
}

extension TranscriptionService: Transcriber {}
extension RecapService: RecapBackend {}
