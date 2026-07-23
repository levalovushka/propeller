import AVFoundation
import Foundation
import FluidAudio
import SpeakerMatchingCore

struct MeetingTranscriptionResult {
    var transcript: String
    /// Per-segment view of the transcript with resolved speaker names.
    /// Persisted on RecordingEntry to power per-segment reassignment.
    var mergedSegments: [PersistedSegment]
}

/// Intermediate result after the ASR pass but before diarization.
/// Stored as a checkpoint so a crash mid-diarization doesn't lose the expensive ASR output.
struct RawTranscriptionResult {
    let segments: [ASRSegment]
    let rawText: String
}

class TranscriptionService {
    private(set) var diarizer: OfflineDiarizerManager?
    private var gigasttReady = false

    /// Ensure the diarizer is loaded (without touching ASR).
    func prepareDiarizer() async throws -> OfflineDiarizerManager {
        if let existing = diarizer { return existing }
        let diaConfig = OfflineDiarizerConfig()
        let dia = OfflineDiarizerManager(config: diaConfig)
        try await dia.prepareModels()
        diarizer = dia
        return dia
    }

    // MARK: - Setup

    /// Verify gigastt HTTP is reachable (starting the sidecar if needed) and load FluidAudio diarizer.
    func prepare(
        downloadProgress: ((Double) -> Void)? = nil,
        statusCallback: ((String) -> Void)? = nil
    ) async throws {
        if !gigasttReady {
            statusCallback?("Starting gigastt…")
            downloadProgress?(0.05)
            try await GigasttSidecar.shared.ensureReady(
                statusCallback: statusCallback,
                downloadProgress: { frac in
                    // Reserve 0.05–0.85 for model download / server boot
                    downloadProgress?(0.05 + frac * 0.8)
                }
            )
            let health = try await GigasttClient.health(baseURL: GigasttSidecar.baseURL)
            gigasttReady = true
            downloadProgress?(0.9)
            NSLog("[TranscriptionService] gigastt ready: model=\(health.model ?? "?") variant=\(health.variant ?? "?") version=\(health.version ?? "?")")
        }

        if diarizer == nil {
            statusCallback?("Loading diarizer...")
            let diaConfig = OfflineDiarizerConfig()
            diarizer = OfflineDiarizerManager(config: diaConfig)
            try await diarizer?.prepareModels()
        }
        downloadProgress?(1.0)
    }

    // MARK: - Transcribe

    /// Full pipeline: ASR → diarization → formatted transcript.
    func transcribe(
        audioURL: URL,
        languageOverride: String? = nil,
        progressCallback: ((String) -> Void)? = nil,
        downloadProgress: ((Double) -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        let raw = try await transcribeAudio(
            audioURL: audioURL,
            languageOverride: languageOverride,
            progressCallback: progressCallback,
            downloadProgress: downloadProgress
        )
        return try await diarize(
            audioURL: audioURL,
            asrSegments: raw.segments,
            progressCallback: progressCallback
        )
    }

    // MARK: - Phase 1: ASR (the expensive step)

    /// Run gigastt transcription only. Returns raw segments that can be
    /// serialized as a checkpoint before the diarization pass.
    /// `languageOverride` is ignored — GigaAM is Russian-only.
    func transcribeAudio(
        audioURL: URL,
        languageOverride: String? = nil,
        progressCallback: ((String) -> Void)? = nil,
        downloadProgress: ((Double) -> Void)? = nil
    ) async throws -> RawTranscriptionResult {
        _ = languageOverride // fixed ru via GigaAM
        progressCallback?("Loading models...")
        try await prepare(
            downloadProgress: downloadProgress,
            statusCallback: progressCallback
        )

        progressCallback?("Transcribing audio (GigaAM)...")
        NSLog("[TranscriptionService] Starting gigastt transcription for: \(audioURL.lastPathComponent)")

        let (segments, rawText) = try await GigasttClient.transcribe(
            audioURL: audioURL,
            baseURL: GigasttSidecar.baseURL
        )

        NSLog("[TranscriptionService] gigastt returned \(segments.count) segment(s)")
        for (i, seg) in segments.prefix(3).enumerated() {
            NSLog("[TranscriptionService]   Segment \(i): [\(seg.start)-\(seg.end)] \"\(seg.text.prefix(80))\"")
        }

        guard !segments.isEmpty else {
            NSLog("[TranscriptionService] ERROR: empty segments")
            throw TranscriptionError.noResults
        }

        return RawTranscriptionResult(segments: segments, rawText: rawText)
    }

    // MARK: - Phase 2: Diarization + Speaker Matching

    /// Run diarization, merge with ASR segments, and label speakers.
    /// Can be called independently to resume after a crash between phases.
    ///
    /// No voice-matching library: every diarized cluster is "Speaker N" by
    /// default. The one exception is the recording owner — the cluster most
    /// dominantly captured on the microphone stem (vs. the system stem) is
    /// labeled with the user's name from onboarding, since that's a reliable,
    /// zero-configuration signal (see plan-v2 3.3).
    func diarize(
        audioURL: URL,
        asrSegments: [ASRSegment],
        progressCallback: ((String) -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        if diarizer == nil {
            progressCallback?("Loading diarizer...")
            _ = try await prepareDiarizer()
        }

        progressCallback?("Identifying speakers...")
        var diarizedSegments: [DiarizedSegment] = []

        if let diarizer = diarizer {
            do {
                let diaResult = try await diarizer.process(audioURL)
                diarizedSegments = diaResult.segments.map { seg in
                    DiarizedSegment(
                        speakerId: seg.speakerId,
                        startTime: seg.startTimeSeconds,
                        endTime: seg.endTimeSeconds,
                        embedding: seg.embedding,
                        qualityScore: seg.qualityScore
                    )
                }
            } catch {
                print("Diarization failed: \(error). Continuing without speaker labels.")
            }
        }

        let mergedSegments = mergeTranscriptionWithDiarization(
            asrSegments: asrSegments,
            diarization: diarizedSegments
        )

        let speakerNameMap = Self.resolveOwnerName(
            mergedSegments: mergedSegments,
            diarizedSegments: diarizedSegments,
            audioURL: audioURL
        )

        let unmerged = mergedSegments.filter { !$0.text.isEmpty }
        let persisted: [PersistedSegment] = unmerged.enumerated().map { idx, seg in
            PersistedSegment(
                index: idx,
                startTime: Double(seg.startTime),
                endTime: Double(seg.endTime),
                text: seg.text,
                speaker: speakerNameMap[seg.speakerLabel] ?? seg.speakerLabel
            )
        }

        let transcript = TranscriptionService.formatTranscriptText(from: persisted)

        return MeetingTranscriptionResult(
            transcript: transcript,
            mergedSegments: persisted
        )
    }

    /// Among the diarized speaker clusters, find the one most dominantly
    /// captured via the microphone stem (vs. the system stem) — that's the
    /// recording owner. If several clusters classify as mic-dominant (e.g. a
    /// mic-only recording with no system stem to compare against), the one
    /// with the most total talk time wins. Returns a `["Speaker N": name]`
    /// map with at most one entry; empty if the user's name isn't set or no
    /// cluster qualifies.
    private static func resolveOwnerName(
        mergedSegments: [MergedSegment],
        diarizedSegments: [DiarizedSegment],
        audioURL: URL
    ) -> [String: String] {
        let ownerName = Preferences.shared.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ownerName.isEmpty else { return [:] }

        var best: (label: String, talkTime: Float)?
        for label in Set(mergedSegments.map(\.speakerLabel)) {
            let spkId = label.replacingOccurrences(of: "Speaker ", with: "")
            let speakerSegs = diarizedSegments.filter { $0.speakerId == spkId }
            guard !speakerSegs.isEmpty else { continue }

            let report = AudioSourceEnergyClassifier.analyze(
                finalAudioURL: audioURL,
                windows: speakerSegs.map { Double($0.startTime)...Double($0.endTime) }
            )
            guard report.source == .microphone else { continue }

            let talkTime = speakerSegs.reduce(Float(0)) { $0 + ($1.endTime - $1.startTime) }
            if talkTime > (best?.talkTime ?? -1) {
                best = (label, talkTime)
            }
        }

        guard let best else { return [:] }
        return [best.label: ownerName]
    }

    /// Re-render the transcript text from a `[PersistedSegment]` snapshot.
    static func formatTranscriptText(from segments: [PersistedSegment]) -> String {
        let merged = collapseConsecutiveSameSpeaker(segments)
        return merged.compactMap { seg in
            guard !seg.text.isEmpty else { return nil }
            let m = Int(seg.startTime) / 60
            let s = Int(seg.startTime) % 60
            return "[\(seg.speaker)] [\(String(format: "%02d:%02d", m, s))]\n\(seg.text)"
        }.joined(separator: "\n\n")
    }

    private static func collapseConsecutiveSameSpeaker(
        _ segments: [PersistedSegment],
        maxGap: Double = 5.0
    ) -> [PersistedSegment] {
        var out: [PersistedSegment] = []
        for seg in segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = out.last,
               last.speaker == seg.speaker,
               (seg.startTime - last.endTime) <= maxGap {
                out.removeLast()
                out.append(PersistedSegment(
                    index: last.index,
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    text: last.text + " " + trimmed,
                    speaker: last.speaker
                ))
            } else {
                out.append(PersistedSegment(
                    index: seg.index,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: trimmed,
                    speaker: seg.speaker
                ))
            }
        }
        return out
    }

    // MARK: - Merge ASR + Diarization

    private struct MergedSegment {
        let startTime: Float
        let endTime: Float
        let text: String
        let speakerLabel: String
    }

    private struct DiarizedSegment {
        let speakerId: String
        let startTime: Float
        let endTime: Float
        let embedding: [Float]
        let qualityScore: Float
    }

    private func mergeTranscriptionWithDiarization(
        asrSegments: [ASRSegment],
        diarization: [DiarizedSegment]
    ) -> [MergedSegment] {
        if diarization.isEmpty {
            return asrSegments.map { seg in
                MergedSegment(
                    startTime: seg.start,
                    endTime: seg.end,
                    text: cleanASRText(seg.text),
                    speakerLabel: "Speaker"
                )
            }
        }

        return asrSegments.map { seg in
            let midpoint: Float = (seg.start + seg.end) / 2.0
            let speaker: String
            if let match = diarization.first(where: { midpoint >= $0.startTime && midpoint <= $0.endTime }) {
                speaker = "Speaker \(match.speakerId)"
            } else if let closest = diarization.min(by: {
                abs(($0.startTime + $0.endTime) / 2 - midpoint) < abs(($1.startTime + $1.endTime) / 2 - midpoint)
            }) {
                speaker = "Speaker \(closest.speakerId)"
            } else {
                speaker = "Speaker"
            }

            return MergedSegment(
                startTime: seg.start,
                endTime: seg.end,
                text: cleanASRText(seg.text),
                speakerLabel: speaker
            )
        }
    }

    // MARK: - Format

    private func cleanASRText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeConsecutiveSameSpeaker(_ segments: [MergedSegment], maxGap: Float = 5.0) -> [MergedSegment] {
        guard !segments.isEmpty else { return segments }
        var out: [MergedSegment] = []
        for seg in segments {
            let text = cleanASRText(seg.text)
            guard !text.isEmpty else { continue }
            if let last = out.last,
               last.speakerLabel == seg.speakerLabel,
               (seg.startTime - last.endTime) <= maxGap {
                let combined = MergedSegment(
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    text: last.text + " " + text,
                    speakerLabel: last.speakerLabel
                )
                out.removeLast()
                out.append(combined)
            } else {
                out.append(MergedSegment(
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: text,
                    speakerLabel: seg.speakerLabel
                ))
            }
        }
        return out
    }

    private func formatTranscript(_ segments: [MergedSegment], speakerNames: [String: String]) -> String {
        let merged = mergeConsecutiveSameSpeaker(segments)
        return merged.compactMap { seg in
            let name = speakerNames[seg.speakerLabel] ?? seg.speakerLabel
            guard !seg.text.isEmpty else { return nil }
            let m = Int(seg.startTime) / 60
            let s = Int(seg.startTime) % 60
            return "[\(name)] [\(String(format: "%02d:%02d", m, s))]\n\(seg.text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Engine info (Settings UI)

    static let engineDescription = "GigaAM v3 (e2e_rnnt) via local gigastt"

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case noResults

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "gigastt is not available. The speech engine failed to start."
            case .noResults:
                return "No transcription results produced."
            }
        }
    }
}
