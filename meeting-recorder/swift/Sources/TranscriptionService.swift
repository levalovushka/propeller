import AVFoundation
import Foundation
import FluidAudio
import SpeakerMatchingCore

struct MeetingTranscriptionResult {
    var transcript: String
    var detectedSpeakers: [DetectedSpeaker]
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

    /// Ensure the diarizer is loaded (without touching ASR). Used by
    /// PeopleStore's re-embed flow when we only need embeddings.
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

    /// Full pipeline: ASR → diarization → speaker matching → formatted transcript.
    func transcribe(
        audioURL: URL,
        peopleStore: PeopleStore,
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
        return try await diarizeAndMatch(
            audioURL: audioURL,
            asrSegments: raw.segments,
            peopleStore: peopleStore,
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

    /// Run diarization, merge with ASR segments, match speakers, format transcript.
    /// Can be called independently to resume after a crash between phases.
    func diarizeAndMatch(
        audioURL: URL,
        asrSegments: [ASRSegment],
        peopleStore: PeopleStore,
        progressCallback: ((String) -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        if diarizer == nil {
            progressCallback?("Loading diarizer...")
            _ = try await prepareDiarizer()
        }

        progressCallback?("Identifying speakers...")
        var diarizedSegments: [DiarizedSegment] = []
        var speakerDB: [String: [Float]] = [:]

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
                speakerDB = diaResult.speakerDatabase ?? [:]
            } catch {
                print("Diarization failed: \(error). Continuing without speaker labels.")
            }
        }

        progressCallback?("Matching speakers...")
        let mergedSegments = mergeTranscriptionWithDiarization(
            asrSegments: asrSegments,
            diarization: diarizedSegments
        )

        var speakerNameMap: [String: String] = [:]
        var detectedSpeakers: [DetectedSpeaker] = []

        struct SpeakerCandidate {
            let label: String
            let embedding: [Float]
            let sampleStart: Double
            let sampleEnd: Double
            let qualityScore: Float?
            let captureSource: AudioCaptureSource
        }

        let uniqueSpeakers = Set(mergedSegments.map(\.speakerLabel))
        var candidates: [SpeakerCandidate] = []
        for label in uniqueSpeakers {
            let spkId = label.replacingOccurrences(of: "Speaker ", with: "")
            let speakerSegs = diarizedSegments.filter { $0.speakerId == spkId }

            let embedding: [Float]
            if let db = speakerDB[spkId], !db.isEmpty {
                embedding = db
            } else if let segEmb = speakerSegs.first(where: { !$0.embedding.isEmpty })?.embedding {
                embedding = segEmb
            } else {
                speakerNameMap[label] = label
                continue
            }

            let window = Self.pickSampleWindow(for: spkId, allSegments: diarizedSegments)
            let quality = speakerSegs.map(\.qualityScore).max()
            let sourceReport = AudioSourceEnergyClassifier.analyze(
                finalAudioURL: audioURL,
                windows: speakerSegs.map { Double($0.startTime)...Double($0.endTime) }
            )
            candidates.append(SpeakerCandidate(
                label: label,
                embedding: embedding,
                sampleStart: window.start,
                sampleEnd: window.end,
                qualityScore: quality,
                captureSource: sourceReport.source
            ))
        }

        struct MatchTriple {
            let speakerLabel: String
            let person: Person
            let score: Float
        }

        let autoThreshold: Float = Preferences.shared.autoMatchThreshold
        var allTriples: [MatchTriple] = []
        let allPeople = await MainActor.run { peopleStore.people }
        for candidate in candidates {
            for person in allPeople {
                let score = await MainActor.run {
                    peopleStore.bestSimilarity(
                        embedding: candidate.embedding,
                        source: candidate.captureSource,
                        to: person
                    )
                }
                if score >= autoThreshold {
                    allTriples.append(MatchTriple(speakerLabel: candidate.label, person: person, score: score))
                }
            }
        }

        allTriples.sort { $0.score > $1.score }
        var assignedPersonIDs = Set<UUID>()
        var assignedSpeakers = Set<String>()
        var speakerToMatch: [String: (person: Person, score: Float)] = [:]

        for triple in allTriples {
            if assignedPersonIDs.contains(triple.person.id) { continue }
            if assignedSpeakers.contains(triple.speakerLabel) { continue }
            speakerToMatch[triple.speakerLabel] = (triple.person, triple.score)
            assignedPersonIDs.insert(triple.person.id)
            assignedSpeakers.insert(triple.speakerLabel)
        }

        for candidate in candidates {
            let matchResult = await MainActor.run {
                peopleStore.matchWithRecommendations(
                    embedding: candidate.embedding,
                    source: candidate.captureSource,
                    autoThreshold: autoThreshold,
                    recommendThreshold: Preferences.shared.recommendThreshold
                )
            }

            let autoMatch = speakerToMatch[candidate.label]
            let name = autoMatch?.person.name ?? candidate.label
            speakerNameMap[candidate.label] = name

            let filteredRecs = matchResult.recommendations.filter { rec in
                if rec.person.id == autoMatch?.person.id { return false }
                if assignedPersonIDs.contains(rec.person.id) && autoMatch?.person.id != rec.person.id {
                    return false
                }
                return true
            }

            detectedSpeakers.append(DetectedSpeaker(
                label: candidate.label,
                embedding: candidate.embedding,
                matchedPerson: autoMatch?.person,
                matchScore: autoMatch?.score,
                assignedName: name,
                sampleStartTime: candidate.sampleStart,
                sampleEndTime: candidate.sampleEnd,
                sampleQuality: candidate.qualityScore,
                captureSource: candidate.captureSource,
                recommendations: filteredRecs
            ))
        }

        let unmerged = mergedSegments.filter { !$0.text.isEmpty }
        let persisted: [PersistedSegment] = unmerged.enumerated().map { idx, seg in
            PersistedSegment(
                index: idx,
                startTime: Double(seg.startTime),
                endTime: Double(seg.endTime),
                text: seg.text,
                speaker: speakerNameMap[seg.speakerLabel] ?? seg.speakerLabel,
                personID: nil
            )
        }

        let transcript = TranscriptionService.formatTranscriptText(from: persisted)

        return MeetingTranscriptionResult(
            transcript: transcript,
            detectedSpeakers: detectedSpeakers,
            mergedSegments: persisted
        )
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
                    speaker: last.speaker,
                    personID: last.personID
                ))
            } else {
                out.append(PersistedSegment(
                    index: seg.index,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: trimmed,
                    speaker: seg.speaker,
                    personID: seg.personID
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

    private static func pickSampleWindow(
        for speakerId: String,
        allSegments: [DiarizedSegment]
    ) -> (start: Double, end: Double) {
        let own = allSegments.filter { $0.speakerId == speakerId }
        let others = allSegments.filter { $0.speakerId != speakerId }

        func cleanDuration(_ seg: DiarizedSegment) -> Float {
            let segDur = seg.endTime - seg.startTime
            guard segDur > 0 else { return 0 }
            var overlapped: Float = 0
            for o in others {
                let overlapStart = max(seg.startTime, o.startTime)
                let overlapEnd = min(seg.endTime, o.endTime)
                if overlapEnd > overlapStart {
                    overlapped += (overlapEnd - overlapStart)
                }
            }
            return max(0, segDur - overlapped)
        }

        let ranked = own
            .map { ($0, cleanDuration($0)) }
            .sorted { $0.1 > $1.1 }

        let minTarget: Float = 3
        let maxTarget: Float = 15

        for (seg, clean) in ranked where clean >= minTarget {
            let headroom: Float = (seg.endTime - seg.startTime) > (minTarget + 1) ? 0.5 : 0
            let start = seg.startTime + headroom
            let end = min(start + maxTarget, seg.endTime)
            return (Double(start), Double(end))
        }

        if let first = own.first {
            let end = min(first.startTime + 10, first.endTime)
            return (Double(first.startTime), Double(end))
        }

        return (0, 10)
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
