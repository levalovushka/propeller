import AVFoundation
import CoreML
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
        let configuration = engineConfiguration(for: readDiarizerAttempts().plan)
        do {
            dia.initialize(models: try await OfflineDiarizerModels.load(
                from: directory, configuration: configuration))
        } catch {
            NSLog("[TranscriptionService] диаризатор не загрузился (\(error.localizedDescription)) — чищу кэш и качаю заново")
            let repo = directory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
            try? FileManager.default.removeItem(at: repo)
            dia.initialize(models: try await OfflineDiarizerModels.load(
                from: directory, configuration: configuration))
        }
    }

    /// Чем исполнять модели на этой попытке.
    ///
    /// `nil` — умолчание библиотеки, то есть то, что работает у всех. Второй
    /// заход снимает GPU и оставляет нейродвижок с процессором: падает
    /// `MLE5Engine` на пути BNNS/CPU, и это единственный рычаг, который у нас
    /// есть, не форкая FluidAudio. **Догадка, не замер** — машины с macOS 14 у
    /// нас нет. Стоит она ровно одну попытку: не поможет — счётчик дойдёт до
    /// предела и кластеризация выключится сама.
    private static func engineConfiguration(for plan: DiarizerAttempts.Plan) -> MLModelConfiguration? {
        guard plan == .alternateEngine else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        NSLog("[TranscriptionService] прошлая диаризация убила процесс — пробую .cpuAndNeuralEngine")
        Analytics.diarizeFallback(stage: "retry_engine")
        return configuration
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
        systemStemOffset: Double = 0,
        progressCallback: ((String) -> Void)? = nil,
        downloadProgress: ((Double) -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        let raw = try await transcribeAudio(
            audioURL: audioURL,
            languageOverride: languageOverride,
            systemStemOffset: systemStemOffset,
            progressCallback: progressCallback,
            downloadProgress: downloadProgress
        )
        return try await diarize(
            audioURL: audioURL,
            asrSegments: raw.segments,
            systemStemOffset: systemStemOffset,
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
        /// Где начало системного стема на часах встречи. На нынешнем пути захвата
        /// всегда 0 — обе дорожки читает одна IOProc, — но микшер умеет ставить
        /// стем со сдвигом, и тогда времена его реплик надо привести к встрече.
        systemStemOffset: Double = 0,
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
        ) { () async throws -> (segments: [ASRSegment], rawText: String) in
            // Есть обе дорожки — читаем их по отдельности, а не микс. Микс
            // теряет слова там, где стороны говорят одновременно: замерено на
            // «Обеде» (58 минут, колонки) — до транскрипта доходит 57.1 % слов
            // собеседника, остальные затирает своя же речь. Из дорожек по
            // построению не теряется ничего.
            if let stems = Self.usableStems(for: audioURL) {
                return try await Self.transcribeStems(
                    stems,
                    systemStemOffset: systemStemOffset,
                    progressCallback: progressCallback
                )
            }
            let result = try await GigasttClient.transcribe(
                audioURL: audioURL,
                baseURL: GigasttSidecar.baseURL,
                progressCallback: progressCallback
            )
            return (result.segments, result.rawText)
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

    // MARK: - Две дорожки вместо микса

    /// Расшифровать обе дорожки и собрать из них реплики владельца и остальных.
    ///
    /// Диаризации здесь нет: она в следующей фазе и только по системному стему.
    /// Возвращаются реплики, помеченные дорожкой, — это и есть чекпойнт. Слова с
    /// таймингами в него не едут: эхо снимается здесь и сейчас, а слова весили бы
    /// как второй транскрипт в файле индекса.
    ///
    /// Пустая дорожка — не сбой: владелец мог молчать всю встречу (доклад
    /// коллеги), а на встрече вживую наоборот молчит системный стем. Ноль на
    /// обеих — это «никто не говорил», и оно обязано остаться терминальным
    /// (`SilentRecording`), иначе очередь будет вечно перечитывать тот же файл.
    private static func transcribeStems(
        _ stems: AudioSourceStemURLs,
        systemStemOffset: Double,
        progressCallback: ((String) -> Void)?
    ) async throws -> (segments: [ASRSegment], rawText: String) {
        let mic = try await transcribeStem(stems.microphoneURL, progressCallback: progressCallback)
        let sys = try await transcribeStem(stems.systemURL, progressCallback: progressCallback)
        guard mic != nil || sys != nil else { throw TranscriptionError.noResults }

        let farSegments = (sys?.segments ?? []).map {
            ASRSegment(
                start: $0.start + Float(systemStemOffset),
                end: $0.end + Float(systemStemOffset),
                text: $0.text,
                stem: .system
            )
        }
        let farWords = (sys?.words ?? []).map {
            ASRWord(start: $0.start + systemStemOffset, end: $0.end + systemStemOffset, text: $0.text)
        }
        let owner = StemAssembly.ownerLines(
            mic: (mic?.segments ?? []).map {
                EchoDedup.Line(start: Double($0.start), end: Double($0.end), text: $0.text)
            },
            micWords: mic?.words ?? [],
            farSide: farSegments.map {
                EchoDedup.Line(start: Double($0.start), end: Double($0.end), text: $0.text)
            },
            farWords: farWords
        )
        NSLog(
            "[TranscriptionService] стемы: микрофон %d реплик → %d своих, системный %d",
            mic?.segments.count ?? 0, owner.count, farSegments.count
        )

        let segments = (owner.map {
            ASRSegment(start: Float($0.start), end: Float($0.end), text: $0.text, stem: .microphone)
        } + farSegments)
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return (segments, segments.map(\.text).joined(separator: " "))
    }

    /// Одна дорожка. `nil` — сайдкар ответил и слов не нашёл.
    private static func transcribeStem(
        _ url: URL,
        progressCallback: ((String) -> Void)?
    ) async throws -> GigasttClient.ASRResult? {
        do {
            return try await GigasttClient.transcribe(
                audioURL: url,
                baseURL: GigasttSidecar.baseURL,
                progressCallback: progressCallback
            )
        } catch GigasttClient.ClientError.emptyResult {
            NSLog("[TranscriptionService] на дорожке \(url.lastPathComponent) речи нет")
            return nil
        }
    }

    /// Дорожки, по которым можно работать вместо микса.
    private static func usableStems(for finalAudioURL: URL) -> AudioSourceStemURLs? {
        guard hasUsableStems(for: finalAudioURL) else { return nil }
        return AudioSourceStemURLs.expectedSiblings(for: finalAudioURL)
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
                Analytics.diarizeFallback(stage: "unavailable")
            }
        }

        progressCallback?("Определяем спикеров…")
        var diarizedSegments: [DiarizedSegment] = []

        // Реплики пришли с дорожек — значит владелец известен по построению, и
        // кластеризовать надо **только системный стем**: в нём владельца нет
        // вовсе, и диаризации больше не приходится отделять его голос от его же
        // эха. На миксе это была её главная работа и главный промах.
        let stems = Self.usableStems(for: audioURL)
        let ownerFromStem = asrSegments.contains { $0.stem == .microphone }
        let fromStems = ownerFromStem || asrSegments.contains { $0.stem == .system }
        let diarizationTarget = (fromStems ? stems?.systemURL : nil) ?? audioURL

        // Дважды подряд не вернувшись из кластеризации, больше её не зовём: на
        // macOS 14 она убивает процесс сигналом, а сигнал не перехватить. Метка
        // ставится **до** вызова и переживает смерть — только так у петли
        // появляется выход.
        var attempts = Self.readDiarizerAttempts()
        if diarizer != nil, !attempts.mayRun {
            NSLog("[TranscriptionService] диаризация убила процесс \(attempts.unfinished) раза подряд — спикеры по дорожкам")
            Analytics.diarizeFallback(stage: "disabled_after_crash")
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
                    try await diarizer.process(diarizationTarget)
                }
                // Диаризация системного стема считает время от начала стема, а
                // реплики уже приведены к часам встречи — сдвиг тот же.
                let shift = Float(diarizationTarget == audioURL ? 0 : systemStemOffset)
                diarizedSegments = diaResult.segments.map { seg in
                    DiarizedSegment(
                        speakerId: seg.speakerId,
                        startTime: seg.startTimeSeconds + shift,
                        endTime: seg.endTimeSeconds + shift,
                        embedding: seg.embedding,
                        qualityScore: seg.qualityScore
                    )
                }
            } catch {
                print("Diarization failed: \(error). Continuing without speaker labels.")
            }
        }

        if fromStems {
            return assembleFromStems(
                asrSegments: asrSegments,
                diarization: diarizedSegments,
                callPolls: Self.loadCallPolls(for: audioURL),
                progressCallback: progressCallback
            )
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

    /// Собрать ленту из помеченных дорожкой реплик.
    ///
    /// Кто говорит, здесь не оценивается: микрофонная реплика после снятия эха —
    /// владелец по построению, системная — кто-то из остальных, и вопрос только в
    /// том, как их назвала кластеризация. Энергия дорожек не сравнивается вообще
    /// (`captureSource` на этом пути не вызывается): сравнение громкостей — то
    /// самое правило, которое замер 2026-08-11 опроверг.
    private func assembleFromStems(
        asrSegments: [ASRSegment],
        diarization: [DiarizedSegment],
        callPolls: [CallWindowJournal.Poll] = [],
        progressCallback: ((String) -> Void)?
    ) -> MeetingTranscriptionResult {
        let ownerName = Preferences.shared.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = asrSegments.filter { $0.stem == .microphone && !$0.text.isEmpty }.map {
            StemMerge.Line(
                start: Double($0.start),
                end: Double($0.end),
                speaker: ownerName.isEmpty ? SourceAwareSpeaker.defaultOwnerName : ownerName,
                text: $0.text
            )
        }
        // Кластеризация ставит метки только дальней стороне — она одна и
        // кластеризовалась.
        let labelled = mergeTranscriptionWithDiarization(
            asrSegments: asrSegments.filter { $0.stem == .system },
            diarization: diarization
        )
        // Журнал окна звонилки — источник атрибуции выше диаризации, и только
        // для чужих реплик: владельца атрибутирует микрофонный стем (факт
        // сильнее), а Zoom-имя владельца в ленту не попадает — иначе он
        // раздваивается. Молчание журнала закрывает диаризация, как и было.
        // Та же машинка, что у живого пути: одно сглаживание, одно правило
        // владельца, один ответ на вопрос «кто говорил в секунду t».
        var machine = CallWindowJournal.LiveSpeaker()
        for poll in callPolls.sorted(by: { $0.t < $1.t }) { machine.take(poll) }
        for line in owner { machine.noteOwnerTurn(start: line.start, end: line.end) }
        var journalNamed = 0
        // Кластеризации не было (не загрузилась, выключена после падения) —
        // сколько людей на той стороне, узнать нечем, и они одно имя, а не
        // угаданное число (`design/no-dead-ends.md`, Э1).
        let others = labelled.filter { !$0.text.isEmpty }.map { segment -> StemMerge.Line in
            let fallback = diarization.isEmpty
                ? SourceAwareSpeaker.defaultRemoteName
                : segment.speakerLabel
            let named = machine.name(
                at: Double(segment.startTime + segment.endTime) / 2
            )
            if named != nil { journalNamed += 1 }
            return StemMerge.Line(
                start: Double(segment.startTime),
                end: Double(segment.endTime),
                speaker: named ?? fallback,
                text: segment.text
            )
        }

        let lines = StemMerge.merge(owner: owner, others: others)
        let persisted = lines.enumerated().map { index, line in
            PersistedSegment(
                index: index,
                startTime: line.start,
                endTime: line.end,
                text: line.text,
                speaker: line.speaker
            )
        }
        NSLog(
            "[TranscriptionService] лента из дорожек: %d своих + %d чужих (журнал назвал %d) → %d строк",
            owner.count, others.count, journalNamed, persisted.count
        )
        // §8.4: доля встреч с журналом и доля названных чужих реплик.
        if !callPolls.isEmpty {
            Analytics.signal("CallJournal.applied", parameters: [
                "named": String(journalNamed),
                "far": String(others.count),
            ])
        }
        let attribution: SpeakerAttribution
        if journalNamed > 0 {
            attribution = .callWindow
        } else {
            attribution = diarization.isEmpty ? .stems : .diarized
        }
        return MeetingTranscriptionResult(
            transcript: TranscriptionService.formatTranscriptText(from: persisted),
            mergedSegments: persisted,
            attribution: attribution
        )
    }

    /// Трасса окна звонилки, если наблюдатель её писал.
    ///
    /// Времена трассы — секунды от старта записи (якорь ставит наблюдатель),
    /// поэтому машинка отвечает сразу на часах транскрипта, без подгонки
    /// сдвига. Нет файла — нет журнала, и это законное состояние: запись шла
    /// без разрешения, не в Zoom, или наблюдатель не застал плиток.
    private static func loadCallPolls(for audioURL: URL) -> [CallWindowJournal.Poll] {
        let traceURL = audioURL.deletingPathExtension()
            .appendingPathExtension("calltrace.jsonl")
        guard let data = try? Data(contentsOf: traceURL) else { return [] }
        return CallWindowJournal.polls(fromJSONL: data)
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
            // `minutesSeconds`, not `text`: this is the shape every transcript
            // already on disk carries, and the reason is written down there.
            return "[\(seg.speaker)] [\(Timecode.minutesSeconds(Double(seg.startTime)))]\n\(seg.text)"
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
