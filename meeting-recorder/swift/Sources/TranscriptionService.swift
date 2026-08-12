import AVFoundation
import Foundation
import FluidAudio
import PropellerMetrics
import PropellerPure
import SpeakerMatchingCore

struct MeetingTranscriptionResult {
    var transcript: String
    /// Per-segment view of the transcript with resolved speaker names.
    /// Persisted on RecordingEntry to power per-segment reassignment.
    var mergedSegments: [PersistedSegment]
    /// How those names were arrived at — clustered, or the stems alone.
    /// Persisted with the meeting so its card can disclose the difference.
    var attribution: SpeakerAttribution = .diarized
}

/// Intermediate result after the ASR pass but before diarization.
/// Stored as a checkpoint so a crash mid-diarization doesn't lose the expensive ASR output.
struct RawTranscriptionResult {
    let segments: [ASRSegment]
    let rawText: String
}

class TranscriptionService {
    private(set) var diarizer: OfflineDiarizerManager?

    /// Ensure the diarizer is loaded (without touching ASR).
    func prepareDiarizer() async throws -> OfflineDiarizerManager {
        if let existing = diarizer { return existing }
        let dia = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await Self.loadDiarizerModels(into: dia)
        diarizer = dia
        return dia
    }

    /// `prepareModels()` minus its prewarm, and the prewarm is the whole reason
    /// this function exists.
    ///
    /// FluidAudio warms the embedding stack with a deliberately degenerate
    /// input — `samplesPerWindow` zeros and a 1×1×1 segmentation tensor. On
    /// **macOS 14.8.4** that input takes CoreML down the `MLE5Engine` → BNNS CPU
    /// path and kills the process inside `_platform_memmove`, four bytes past a
    /// page boundary. Twenty-five crash reports from one tester, all identical,
    /// all with `prewarmEmbeddingStack` on the stack, none with a real
    /// diarization pass — and the machine crashed on every launch that had a
    /// meeting waiting, because the pipeline reaches this call before it reaches
    /// anything else it could fail at. A signal is not catchable, so there is no
    /// defensive version of calling it.
    ///
    /// Skipping it costs the first real inference its warm-up and nothing else:
    /// FluidAudio itself wraps both prewarms in `try/catch` and only logs the
    /// failure, so the library already treats them as optional. Nobody is waiting
    /// on a keystroke here — this is the background pipeline.
    ///
    /// The retry mirrors `prepareModels`: a first load failure means the cached
    /// repo is broken, so it is removed and the load repeated (that path
    /// downloads afresh). Written out rather than delegated because
    /// `purgeDiarizerRepo` is private to the library.
    /// Метка «зашли в кластеризацию и не вышли», пережившая смерть процесса.
    ///
    /// Файл, а не `UserDefaults`: между `set` и записью на диск проходит время,
    /// которого у нас нет — падение случается через секунды после старта, и
    /// незаписанная метка не спасла бы ни одного из тех запусков. `.atomic`
    /// гарантирует, что к возвращению из `write` данные на диске.
    private static var diarizerAttemptsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meeting Recorder", isDirectory: true)
            .appendingPathComponent("diarizer-attempts")
    }

    private static func readDiarizerAttempts() -> DiarizerAttempts {
        guard let text = try? String(contentsOf: diarizerAttemptsURL, encoding: .utf8),
              let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return DiarizerAttempts() }
        return DiarizerAttempts(unfinished: n)
    }

    private static func writeDiarizerAttempts(_ attempts: DiarizerAttempts) {
        let url = diarizerAttemptsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("\(attempts.unfinished)".utf8).write(to: url, options: .atomic)
    }

    private static func loadDiarizerModels(into dia: OfflineDiarizerManager) async throws {
        let directory = OfflineDiarizerModels.defaultModelsDirectory().standardizedFileURL
        do {
            dia.initialize(models: try await OfflineDiarizerModels.load(from: directory))
        } catch {
            NSLog("[TranscriptionService] диаризатор не загрузился (\(error.localizedDescription)) — чищу кэш и качаю заново")
            let repo = directory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
            try? FileManager.default.removeItem(at: repo)
            dia.initialize(models: try await OfflineDiarizerModels.load(from: directory))
        }
    }

    // MARK: - Setup

    /// Verify gigastt HTTP is reachable (starting the sidecar if needed) and load FluidAudio diarizer.
    func prepare(
        downloadProgress: ((Double) -> Void)? = nil,
        statusCallback: ((String) -> Void)? = nil
    ) async throws {
        // Always ensureReady — cheap when healthy; avoids stale gigasttReady after crash (R5).
        statusCallback?("Запуск gigastt…")
        downloadProgress?(0.05)
        try await GigasttSidecar.shared.ensureReady(
            statusCallback: statusCallback,
            downloadProgress: { frac in
                // Reserve 0.05–0.85 for model download / server boot
                downloadProgress?(0.05 + frac * 0.8)
            }
        )
        let health = try await GigasttClient.health(baseURL: GigasttSidecar.baseURL)
        downloadProgress?(0.9)
        NSLog("[TranscriptionService] gigastt ready: model=\(health.model ?? "?") variant=\(health.variant ?? "?") version=\(health.version ?? "?")")

        if diarizer == nil {
            statusCallback?("Загрузка диаризатора…")
            let dia = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await Self.loadDiarizerModels(into: dia)
            diarizer = dia
        }
        downloadProgress?(1.0)
    }

    /// Drop the diarizer and schedule ASR sidecar idle-stop so idle footprint
    /// isn't GigaAM + FluidAudio all day (plan-optimization E1/E2).
    func releaseHeavyResources() {
        PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.release) {
            diarizer = nil
            GigasttSidecar.shared.stopAfterIdle(45)
        }
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
        progressCallback?("Загрузка моделей…")
        try await prepare(
            downloadProgress: downloadProgress,
            statusCallback: progressCallback
        )

        progressCallback?("Расшифровка (GigaAM)…")
        NSLog("[TranscriptionService] Starting gigastt transcription for: \(audioURL.lastPathComponent)")

        let (segments, rawText) = try await PipelineMetrics.interval(
            PipelineMetrics.pipeline, PipelineMetrics.asr
        ) {
            try await GigasttClient.transcribe(
                audioURL: audioURL,
                baseURL: GigasttSidecar.baseURL,
                progressCallback: progressCallback
            )
        }

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
        /// Where the system stem starts on this recording's timeline. Energy is
        /// compared between the stems, and they do not share an origin.
        systemStemOffset: Double = 0,
        progressCallback: ((String) -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        // A diarizer we cannot load is not a reason to lose an ASR pass that has
        // already succeeded. Its models come over the network, so a first run
        // offline used to throw here — and three attempts later the meeting was
        // parked red with a finished transcript sitting in the checkpoint beside
        // it. Now it degrades: no clustering, speakers by stem
        // (`design/no-dead-ends.md`, Э1).
        if diarizer == nil {
            progressCallback?("Загрузка диаризатора…")
            do {
                _ = try await prepareDiarizer()
            } catch {
                NSLog("[TranscriptionService] diarizer unavailable, splitting by stems: \(error)")
                Analytics.signal("Diarize.unavailable")
            }
        }

        progressCallback?("Определяем спикеров…")
        var diarizedSegments: [DiarizedSegment] = []

        // Дважды подряд не вернувшись из кластеризации, больше её не зовём: на
        // macOS 14 она убивает процесс сигналом, а сигнал не перехватить. Метка
        // ставится **до** вызова и переживает смерть — только так у петли
        // появляется выход.
        var attempts = Self.readDiarizerAttempts()
        if diarizer != nil, !attempts.mayRun {
            NSLog("[TranscriptionService] диаризация убила процесс \(attempts.unfinished) раза подряд — спикеры по дорожкам")
            Analytics.signal("Diarize.disabledAfterCrash")
        } else if let diarizer = diarizer {
            attempts.starting()
            Self.writeDiarizerAttempts(attempts)
            defer {
                // Вернулись — значит живы, чем бы вызов ни кончился.
                attempts.returned()
                Self.writeDiarizerAttempts(attempts)
            }
            do {
                let diaResult = try await PipelineMetrics.interval(
                    PipelineMetrics.pipeline, PipelineMetrics.diarize
                ) {
                    try await diarizer.process(audioURL)
                }
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
            audioURL: audioURL,
            systemStemOffset: systemStemOffset
        )

        let unmerged = mergedSegments.filter { !$0.text.isEmpty }
        let ownerName = Preferences.shared.ownerName
        let useSourceSplit = Self.hasUsableStems(for: audioURL)
        // Clustering happened at all? Nothing downstream can tell from the
        // labels alone — one speaker is a legitimate diarization of a monologue.
        let attribution: SpeakerAttribution = diarizedSegments.isEmpty ? .stems : .diarized
        let persisted: [PersistedSegment] = unmerged.enumerated().map { idx, seg in
            let fluidName = speakerNameMap[seg.speakerLabel] ?? seg.speakerLabel
            let speaker: String
            if useSourceSplit {
                let source = Self.captureSource(
                    audioURL: audioURL,
                    start: Double(seg.startTime),
                    end: Double(seg.endTime),
                    systemStemOffset: systemStemOffset
                )
                speaker = attribution == .stems
                    ? SourceAwareSpeaker.stemsOnly(source: source, ownerName: ownerName)
                    : SourceAwareSpeaker.resolve(
                        fluidDisplayName: fluidName,
                        source: source,
                        ownerName: ownerName
                    )
            } else if attribution == .stems {
                // No clustering *and* no stems to compare (mic-only capture):
                // one voice is all we can honestly claim, and it is the owner's.
                speaker = SourceAwareSpeaker.stemsOnly(source: .microphone, ownerName: ownerName)
            } else {
                speaker = fluidName
            }
            return PersistedSegment(
                index: idx,
                startTime: Double(seg.startTime),
                endTime: Double(seg.endTime),
                text: seg.text,
                speaker: speaker
            )
        }

        let transcript = TranscriptionService.formatTranscriptText(from: persisted)

        return MeetingTranscriptionResult(
            transcript: transcript,
            mergedSegments: persisted,
            attribution: attribution
        )
    }

    /// Re-label already-persisted segments using mic/sys stem energy — no ASR.
    /// Fixes headphone meetings where FluidAudio collapsed everyone into the owner.
    func relabelSegmentsFromStems(
        audioURL: URL,
        segments: [PersistedSegment],
        systemStemOffset: Double = 0
    ) -> [PersistedSegment]? {
        guard Self.hasUsableStems(for: audioURL) else { return nil }
        let ownerName = Preferences.shared.ownerName
        return segments.map { seg in
            let source = Self.captureSource(
                audioURL: audioURL,
                start: seg.startTime,
                end: seg.endTime,
                systemStemOffset: systemStemOffset
            )
            let speaker = SourceAwareSpeaker.resolve(
                fluidDisplayName: seg.speaker,
                source: source,
                ownerName: ownerName
            )
            return PersistedSegment(
                index: seg.index,
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text,
                speaker: speaker
            )
        }
    }

    private static func hasUsableStems(for finalAudioURL: URL) -> Bool {
        let stems = AudioSourceStemURLs.expectedSiblings(for: finalAudioURL)
        guard let mic = stems.existingMicrophoneURL,
              let sys = stems.existingSystemURL else { return false }
        // Tiny/empty sys (header-only) means mic-only capture.
        let sysSize = (try? FileManager.default.attributesOfItem(atPath: sys.path)[.size] as? NSNumber)?.intValue ?? 0
        _ = mic
        return sysSize > 4096
    }

    private static func captureSource(
        audioURL: URL,
        start: Double,
        end: Double,
        systemStemOffset: Double
    ) -> SourceAwareSpeaker.Source {
        // Short ASR phrases need a minimum window or energy is all noise.
        let mid = (start + end) / 2
        let half = max(0.35, (end - start) / 2)
        let window = max(0, mid - half)...(mid + half)
        let report = AudioSourceEnergyClassifier.analyze(
            finalAudioURL: audioURL,
            windows: [window],
            systemStemOffset: systemStemOffset
        )
        switch report.source {
        case .microphone: return .microphone
        case .system: return .system
        case .mixed: return .mixed
        case .unknown: return .unknown
        }
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
        audioURL: URL,
        systemStemOffset: Double
    ) -> [String: String] {
        let ownerName = Preferences.shared.ownerName
        guard !ownerName.isEmpty else { return [:] }

        var best: (label: String, talkTime: Float)?
        for label in Set(mergedSegments.map(\.speakerLabel)) {
            let spkId = label.replacingOccurrences(of: "Speaker ", with: "")
            let speakerSegs = diarizedSegments.filter { $0.speakerId == spkId }
            guard !speakerSegs.isEmpty else { continue }

            let report = AudioSourceEnergyClassifier.analyze(
                finalAudioURL: audioURL,
                windows: speakerSegs.map { Double($0.startTime)...Double($0.endTime) },
                systemStemOffset: systemStemOffset
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

        let windows = diarization.map { (id: $0.speakerId, start: $0.startTime, end: $0.endTime) }
        return asrSegments.map { seg in
            MergedSegment(
                startTime: seg.start,
                endTime: seg.end,
                text: cleanASRText(seg.text),
                speakerLabel: DiarizationMerge.speakerLabel(
                    forMidpoint: (seg.start + seg.end) / 2,
                    diarization: windows
                )
            )
        }
    }

    // MARK: - Format

    private func cleanASRText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // `engineDescription` жила здесь ради строки в настройках. Строки нет
    // (2026-08-07): движок ровно один, выбрать другой нельзя, и назвать его
    // человеку было нечем, кроме имени файла — это не настройка, а справка.

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case noResults

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "gigastt недоступен — не удалось запустить движок речи."
            case .noResults:
                return "Расшифровка ничего не вернула."
            }
        }
    }
}
