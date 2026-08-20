import Foundation
import PropellerPure
import SpeakerMatchingCore

@MainActor
class RecordingStore: ObservableObject {
    @Published var recordings: [RecordingEntry] = []

    /// Прочитан ли индекс с диска.
    ///
    /// «Пусто» и «ещё не знаем» — разные вещи, и до этого флага окно их не
    /// различало: `recordings` пуст в обоих случаях, а `load()` идёт из
    /// `bootstrap()`, то есть уже после первого кадра. На кадр между ними окно
    /// с полным архивом успевало показать «Запишем первую встречу?» и тут же
    /// смениться на список — то самое моргание.
    ///
    /// `@Published`, потому что у пустого архива это единственное, что меняется:
    /// `recordings` как был `[]`, так и остаётся, и без этого поля вид, решивший
    /// «ещё не знаем», не узнал бы, что теперь знает.
    @Published private(set) var didLoad = false

    private var pendingSaveWork: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.2

    /// Где лежит архив — один тип вместо путей, собираемых заново в каждом
    /// месте. Читается из настроек каждый раз: человек может сменить папку, и
    /// стирание обязано идти по той, которая настроена сейчас.
    private var layout: ArchiveLayout {
        ArchiveLayout(
            recordingsPath: Preferences.shared.recordingsPath,
            meetingsPath: Preferences.shared.meetingsPath
        )
    }

    private var indexURL: URL { layout.indexURL }

    /// Кого человек удалил (`MeetingTombstone`).
    ///
    /// Отдельным файлом, а не полем в записи: к моменту, когда надгробие нужно,
    /// записи в индексе уже нет — в этом всё и дело. Держать её там же
    /// «удалённой» значило бы, что каждый читатель массива обязан помнить про
    /// фильтр, а забытый фильтр — это ровно тот класс ошибок, ради которого
    /// решения вынесены в `PropellerPure`.
    private var tombstonesURL: URL { layout.tombstonesURL }

    /// Надгробия, прочитанные с диска. Живут всю сессию: их читает скан сирот,
    /// а он теперь бегает не только на запуске.
    private var tombstones: [MeetingTombstone] = []

    // MARK: - Load / Save

    /// Schedule a debounced save. Multiple rapid mutations coalesce into one write.
    private func scheduleSave() {
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: work)
    }

    /// Force-flush any pending debounced save immediately. Call on app quit.
    func flush() {
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        save()
    }

    func load() {
        // Через `defer`, а не строкой в конце: у `load()` три выхода — нет
        // файла, разобрали, не разобрали, — и «архив прочитан» верно на всех
        // трёх. Пустой архив, отсутствующий индекс и битый индекс для окна
        // означают одно: спрашивать больше нечего.
        defer { didLoad = true }
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        loadTombstones()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            scanForOrphanRecordings()
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Prefer all-or-nothing; on failure fall through to per-element recovery (C5).
            do {
                recordings = try decoder.decode([RecordingEntry].self, from: data)
            } catch {
                // One bad element must not wipe the archive — decode element-by-element.
                if let array = try JSONSerialization.jsonObject(with: data) as? [Any] {
                    var recovered: [RecordingEntry] = []
                    for item in array {
                        guard JSONSerialization.isValidJSONObject(item),
                              let itemData = try? JSONSerialization.data(withJSONObject: item),
                              let entry = try? decoder.decode(RecordingEntry.self, from: itemData) else {
                            continue
                        }
                        recovered.append(entry)
                    }
                    if recovered.isEmpty { throw error }
                    recordings = recovered
                    NSLog("[RecordingStore] Partial index recovery: \(recovered.count)/\(array.count) entries")
                } else {
                    throw error
                }
            }
            clearFalseManualTitleFlags()
            scanForOrphanRecordings()
            reconcileSummarizedStage()
        } catch {
            // Quarantine the corrupt file BEFORE any rewrite so we never destroy the only copy (C5).
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = indexURL.deletingLastPathComponent()
                .appendingPathComponent("recordings.json.corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: indexURL, to: quarantine)
            NSLog("[RecordingStore] Failed to load recordings index — quarantined to \(quarantine.lastPathComponent): \(error)")
            recordings = []
            scanForOrphanRecordings()
        }
    }

    /// Live title TextField used to call `rename()` on appear, latching every
    /// default "Recording …" title as manual and blocking LLM rename after recap.
    private func clearFalseManualTitleFlags() {
        var changed = false
        for i in recordings.indices {
            guard recordings[i].titleManuallySet == true else { continue }
            guard MeetingTitle.isPlaceholder(recordings[i].title) else { continue }
            recordings[i].titleManuallySet = false
            changed = true
        }
        if changed {
            NSLog("[RecordingStore] Cleared false titleManuallySet on auto-titled recordings")
            scheduleSave()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // No prettyPrinted — multi-MB archives with embedded transcripts (P6).
            let data = try encoder.encode(recordings)
            // Keep a sidecar backup of the previous good index (C5).
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let bak = indexURL.deletingPathExtension().appendingPathExtension("json.bak")
                try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.copyItem(at: indexURL, to: bak)
            }
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("[RecordingStore] Failed to save recordings index: \(error)")
        }
    }

    // MARK: - Надгробия

    private func loadTombstones() {
        tombstones = TombstoneFile.read(tombstonesURL)
    }

    /// Записывается **синхронно**, без дебаунса, и до того, как аудио тронут.
    ///
    /// Весь смысл надгробия — пережить `SIGKILL`, а дебаунс на 0.2 с это ровно
    /// то окно, в котором его не переживёт. Файл крошечный (id и дата), так что
    /// платить за это нечем.
    private func markDeleted(_ id: String) {
        guard !tombstones.contains(where: { $0.id == id }) else { return }
        TombstoneFile.mark(id, in: layout)
        loadTombstones()
    }

    /// ⌘Z: удаления не было. Камень убирается сразу — иначе следующий скан
    /// увидит запись в индексе и надгробие на неё же, и хотя `adoptable`
    /// разрешает этот спор в пользу индекса, оставлять его незачем.
    private func unmarkDeleted(_ id: String) {
        guard tombstones.contains(where: { $0.id == id }) else { return }
        TombstoneFile.unmark(id, in: layout)
        loadTombstones()
    }

    // MARK: - CRUD

    func add(_ entry: RecordingEntry) {
        recordings.insert(entry, at: 0)
        scheduleSave()
    }

    func update(
        id: String,
        transcript: String? = nil,
        status: RecordingStage? = nil,
        duration: Double? = nil,
        language: String?? = nil,
        notes: String?? = nil,
        rawSegmentsJSON: String?? = nil,
        mergedSegmentsJSON: String?? = nil,
        title: String? = nil,
        topics: [String]? = nil,
        tags: [String]? = nil,
        micOnlyCaptured: Bool? = nil,
        systemCaptureAppScoped: Bool? = nil,
        systemStemOffset: Double? = nil,
        speakerAttribution: SpeakerAttribution? = nil,
        lastFailure: PipelineFailure?? = nil,
        recapGeneratorVersion: Int? = nil
    ) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        if let t = transcript {
            recordings[idx].transcript = t
            // Настоящая расшифровка пришла — черновик больше не нужен, и
            // стирается он здесь, а не у вызывающего. Иначе правило «живой
            // текст живёт до расшифровки» держалось бы на памяти каждого, кто
            // однажды напишет `update(transcript:)`, а таких мест уже пять.
            recordings[idx].liveSegmentsJSON = nil
        }
        if let s = status { recordings[idx].status = s }
        if let d = duration { recordings[idx].duration = d }
        if let l = language { recordings[idx].language = l }
        if let n = notes {
            recordings[idx].notes = n
            // The blob was written directly (legacy editors, the overlay's own
            // path). Drop the records so they are re-derived from it rather than
            // drifting away from what every other reader sees.
            recordings[idx].noteItems = nil
        }
        if let r = rawSegmentsJSON { recordings[idx].rawSegmentsJSON = r }
        if let m = mergedSegmentsJSON { recordings[idx].mergedSegmentsJSON = m }
        // Auto-title path: sets the title WITHOUT marking it manual (unlike rename()).
        if let tt = title { recordings[idx].title = tt }
        if let tp = topics { recordings[idx].topics = tp }
        if let tg = tags { recordings[idx].tags = tg }
        if let mo = micOnlyCaptured { recordings[idx].micOnlyCaptured = mo }
        if let sc = systemCaptureAppScoped { recordings[idx].systemCaptureAppScoped = sc }
        if let so = systemStemOffset { recordings[idx].systemStemOffset = so }
        if let sa = speakerAttribution { recordings[idx].speakerAttribution = sa }
        if let lf = lastFailure { recordings[idx].lastFailure = lf }
        if let gv = recapGeneratorVersion { recordings[idx].recapGeneratorVersion = gv }
        scheduleSave()
    }

    /// Черновик живого текста, снятый в момент остановки.
    ///
    /// Отдельным методом, а не полем в `update`: тот принимает пятнадцать
    /// параметров и вызывается отовсюду, а это пишется ровно из одного места и
    /// ровно один раз за встречу. Не перетирает уже расшифрованное — если
    /// настоящий текст успел прийти раньше (короткая встреча, быстрый ASR),
    /// черновику здесь делать нечего.
    func setLiveSegmentsJSON(_ json: String, for id: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        guard recordings[idx].transcript?.isEmpty != false else { return }
        recordings[idx].liveSegmentsJSON = json
        scheduleSave()
    }

    /// Append one note, keeping the records and the legacy blob in step.
    ///
    /// Both are written on purpose: the records are what the pane draws, the
    /// blob is what the overlay, the markdown writer, the recap prompt and
    /// search have always read.
    /// `offsetSeconds` — сколько было на таймере в момент записи заметки. Nil,
    /// когда встреча уже кончилась: у такой заметки нет места в расшифровке, и
    /// притворяться, что есть, значит поставить её в случайную секунду.
    func appendNote(
        id: String,
        text: String,
        at date: Date = Date(),
        offsetSeconds: Double? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        var items = MeetingNotes.resolved(
            items: recordings[idx].noteItems, blob: recordings[idx].notes
        )
        items.append(
            MeetingNoteRecord(text: trimmed, createdAt: date, offsetSeconds: offsetSeconds)
        )
        recordings[idx].noteItems = items
        recordings[idx].notes = MeetingNotes.blob(from: items)
        scheduleSave()
    }

    func rename(id: String, to newTitle: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].title = newTitle
        // Manual rename latches: LLM/calendar auto-title must not overwrite it.
        recordings[idx].titleManuallySet = true
        scheduleSave()
    }

    /// Delete only audio files; keep the recording entry with transcript
    func deleteAudioFile(for entry: RecordingEntry) {
        for url in audioFileURLs(for: entry) {
            try? FileManager.default.removeItem(at: url)
        }
        // Duration is preserved so the user still sees the original length
        scheduleSave()
    }

    /// Стереть встречу целиком: аудио и стемы, расшифровка и конспект в
    /// `meetings/`, строка индекса, та же строка во всех копиях индекса,
    /// надгробие. И всё, что появится позже и будет названо по встрече —
    /// правило в `ArchiveEraser` спрашивает имя файла, а не список видов.
    ///
    /// До этого уходили только аудио и строка индекса, а расшифровка с конспектом
    /// оставались сиротами навсегда (STATE, компонент 5, rev-9), и `.bak` держал
    /// целую копию удалённой записи вместе с транскриптом.
    ///
    /// Надгробие ставится **до** того, как тронут первый файл: если стереть не
    /// удалось — том отмонтирован, файл занят, — камень остаётся, и дочистка
    /// доведёт дело (`ArchiveEraser.finishPendingErasures`).
    func remove(_ entry: RecordingEntry) {
        markDeleted(entry.id)
        // Из памяти и на диск **до** стирания: `flush()` сбрасывает и чужие
        // отложенные правки, а стирание потом перепишет индекс и его копии уже
        // без этой строки. Обратный порядок дал бы отложенному `save()` шанс
        // вернуть стёртую запись обратно.
        recordings.removeAll { $0.id == entry.id }
        flush()
        let residue = ArchiveEraser.erase(meeting: entry.id, in: layout)
        loadTombstones()
        if !residue.isEmpty {
            // Не отказ и не тупик: камень на месте, дочистка придёт. Но соврать
            // «стёрто» про то, что осталось, нельзя.
            NSLog("[RecordingStore] \(entry.id): стёрто не всё — \(residue.summary)")
        }
    }

    /// Take a meeting out of the list but leave its audio alone.
    ///
    /// Soft-delete for ⌘Z: files stay until `remove` commits (next delete or
    /// quit). An undo that cannot bring the audio back is not an undo.
    ///
    /// Это и есть то окно, в котором удаление раньше не переживало убийство
    /// процесса: записи в индексе уже нет, аудио ещё на месте, а
    /// `commitPendingDeletion` живёт в `applicationWillTerminate`, который при
    /// `SIGKILL` не выполняется. Надгробие переживает.
    func removeDeferred(_ entry: RecordingEntry) {
        markDeleted(entry.id)
        recordings.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    /// Put a deferred removal back, newest-first like the rest of the list.
    func restore(_ entry: RecordingEntry) {
        unmarkDeleted(entry.id)
        guard !recordings.contains(where: { $0.id == entry.id }) else { return }
        recordings.append(entry)
        recordings.sort { $0.date > $1.date }
        scheduleSave()
    }

    func recording(for id: String) -> RecordingEntry? {
        recordings.first { $0.id == id }
    }

    func audioURL(for entry: RecordingEntry) -> URL? {
        let url = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(entry.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func audioFileURLs(for entry: RecordingEntry) -> [URL] {
        let finalURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(entry.filename)
        let stems = AudioSourceStemURLs.expectedSiblings(for: finalURL)
        return [finalURL, stems.microphoneURL, stems.systemURL]
    }

    /// Sum of final mix + mic/sys stems on disk (markdown is negligible).
    func totalLibraryBytes() -> Int64 {
        recordings.reduce(Int64(0)) { $0 + byteSize(of: $1) }
    }

    func byteSize(of entry: RecordingEntry) -> Int64 {
        let fm = FileManager.default
        return audioFileURLs(for: entry).reduce(Int64(0)) { sum, url in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return sum }
            return sum + size
        }
    }

    /// Встречи, у которых аудио уже ничего не держит (`AudioReclaim`).
    func reclaimableAudioEntries() -> [RecordingEntry] {
        recordings.filter {
            AudioReclaim.isExpendable(
                stage: $0.status,
                hasTranscript: $0.transcript?.isEmpty == false
            )
        }
    }

    /// Сколько освободит «Очистить». Не `totalLibraryBytes`: у идущей записи и у
    /// встречи, которую ещё не расшифровали, аудио не забирают, и обещать их
    /// байты нельзя.
    func reclaimableAudioBytes() -> Int64 {
        reclaimableAudioEntries().reduce(Int64(0)) { $0 + byteSize(of: $1) }
    }

    /// Убрать аудио у всех, у кого оно лишнее. Возвращает, у скольких встреч.
    @discardableResult
    func deleteAllReclaimableAudio() -> Int {
        let targets = reclaimableAudioEntries()
        guard !targets.isEmpty else { return 0 }
        let fm = FileManager.default
        for entry in targets {
            for url in audioFileURLs(for: entry) {
                try? fm.removeItem(at: url)
            }
            // Duration is preserved so the user still sees the original length
            // (same rule as the single-file path, `deleteAudioFile(for:)`).
        }
        // Один `save()` на всю чистку, а не по файлу: индекс переписывается
        // целиком, и делать это сто раз подряд — сто шансов поймать половину
        // записанного файла.
        save()
        return targets.count
    }

    // MARK: - Retention

    /// Забрать аудио у всех, чей срок вышел (`AudioRetention`). Возвращает, у
    /// скольких встреч.
    ///
    /// Таймера у этого нет намеренно: «нет причитающейся работы ⇒ нет таймеров»
    /// — инварианты пайплайна. Срок проверяется на тех же событиях, на которых
    /// приложение и так просматривает архив: запуск и конец цепочки воркера.
    /// Пропущенный день ничего не стоит — на следующем событии срок всё ещё
    /// вышел.
    @discardableResult
    func applyAudioRetention(now: Date = Date()) -> Int {
        let mode = Preferences.shared.audioRetentionMode
        guard mode != .keep else { return 0 }
        let candidates = recordings.map {
            AudioRetention.Candidate(
                id: $0.id,
                date: $0.date,
                stage: $0.status,
                hasTranscript: $0.transcript?.isEmpty == false,
                hasAudio: $0.audioFileExists
            )
        }
        let expired = Set(AudioRetention.expired(
            candidates,
            mode: mode,
            days: Preferences.shared.audioRetentionDays,
            now: now
        ))
        guard !expired.isEmpty else { return 0 }
        let fm = FileManager.default
        for entry in recordings where expired.contains(entry.id) {
            for url in audioFileURLs(for: entry) {
                try? fm.removeItem(at: url)
            }
            // Длительность остаётся: человек по-прежнему видит, сколько шла
            // встреча (то же правило, что у ручной чистки).
        }
        NSLog("[RecordingStore] Retention (\(mode.rawValue)): аудио убрано у \(expired.count)")
        save()
        return expired.count
    }

    // MARK: - Стереть человека

    /// Убрать имя человека из всех встреч: метки спикеров, сегменты, проза
    /// конспекта, заголовки, темы, заметки, приглашённые из календаря и slug в
    /// имени файла (`ArchivePersonEraser`).
    ///
    /// Индекс правится **на диске**, а не в памяти, потому что там же лежат его
    /// копии и человек в них тот же. Поэтому после стирания массив
    /// перечитывается: иначе в памяти остался бы прежний текст, и первый же
    /// `save()` вернул бы имя обратно.
    @discardableResult
    func erasePerson(named name: String) -> PersonErasureReport {
        flush()
        let report = ArchivePersonEraser.erase(person: name, in: layout)
        guard !report.filesChanged.isEmpty else { return report }
        load()
        if !report.isComplete {
            NSLog("[RecordingStore] «\(name)» остался в: \(report.remaining.joined(separator: ", "))")
        }
        return report
    }

    /// Drop parked failures for one phase across the archive, returning how many
    /// meetings went back into the queue.
    ///
    /// For when the world changed in a way that makes those failures stale: a
    /// summary model finishing its download invalidates every "Ollama
    /// недоступен" in the index. Without this, installing the model would fix
    /// everything except the meetings that were waiting for it.
    @discardableResult
    func clearFailures(phase: PipelineActivity.Phase) -> Int {
        var cleared = 0
        for i in recordings.indices where recordings[i].lastFailure?.phase == phase.rawValue {
            recordings[i].lastFailure = nil
            cleared += 1
        }
        if cleared > 0 { scheduleSave() }
        return cleared
    }

    // MARK: - Summary stage reconciliation

    /// Bring `.saved` / `.summarized` in line with the recap files actually on
    /// disk. One directory listing for the whole archive, once per launch.
    ///
    /// Runs on every load, not just the first: `.summarized` is a cache of "a
    /// recap exists", and the user can delete the markdown in Obsidian or
    /// Finder. Without the downgrade half, that meeting would never get its
    /// summary back.
    ///
    /// Never guesses when the directory can't be read — an unreadable meetings
    /// folder would otherwise downgrade the entire archive and send it through
    /// the model again.
    func reconcileSummarizedStage() {
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        let recapNames = files.map(\.lastPathComponent).filter { $0.hasSuffix(RecapFile.suffix) }
        var changed = 0
        for i in recordings.indices {
            let id = recordings[i].id
            guard let next = SummaryStageReconciler.reconciled(
                current: recordings[i].status,
                hasRecapFile: recapNames.contains { RecapFile.isRecap($0, for: id) },
                // `topics == nil` is the existing marker for "metadata never ran".
                hasMetadata: recordings[i].topics != nil
            ) else { continue }
            recordings[i].status = next
            changed += 1
        }
        if changed > 0 {
            NSLog("[RecordingStore] Reconciled summary stage on \(changed) recording(s)")
            scheduleSave()
        }
    }

    // MARK: - Recovery

    @discardableResult
    func recoverInterruptedRecordings() -> Int {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        var recoveredCount = 0
        var failedStarts: [String] = []
        for i in recordings.indices where recordings[i].status == .recording {
            let url = dir.appendingPathComponent(recordings[i].filename)
            let stems = AudioSourceStemURLs.expectedSiblings(for: url)
            let hasFinal = FileManager.default.fileExists(atPath: url.path)
            let hasMic = FileManager.default.fileExists(atPath: stems.microphoneURL.path)
            if RecordingRecovery.isFailedStart(
                stage: .recording,
                hasAnyAudio: hasFinal || hasMic,
                hasTranscript: recordings[i].transcript?.isEmpty == false,
                hasNotes: MeetingNotes.resolved(
                    items: recordings[i].noteItems, blob: recordings[i].notes
                ).isEmpty == false
            ) {
                // Ни байта не записалось. Это не встреча, а след неудавшегося
                // старта: чинить нечем, работы ей не причитается, а из списка
                // она не уходит и вечно показывает «Идёт запись».
                failedStarts.append(recordings[i].id)
                continue
            }
            if hasFinal || hasMic {
                if hasFinal {
                    recordings[i].duration = Self.wavDuration(url: url)
                } else if hasMic {
                    // Final mix pending — duration from mic stem until recoverMissingFinalMixes runs.
                    recordings[i].duration = Self.wavDuration(url: stems.microphoneURL)
                }
                if let next = RecordingRecovery.recoveredStage(current: .recording, hasTranscript: false) {
                    recordings[i].status = next
                }
                recoveredCount += 1
            }
        }
        // Recover entries that crashed mid-transcription.
        // If they have a transcript (ASR finished), promote to "transcribed_raw"
        // so the diarization can resume without re-running the expensive ASR pass.
        // Otherwise reset to "recorded" so user can retry from scratch.
        for i in recordings.indices where recordings[i].status == .transcribing {
            let hasTranscript = recordings[i].transcript != nil
            if let next = RecordingRecovery.recoveredStage(current: .transcribing, hasTranscript: hasTranscript) {
                recordings[i].status = next
            }
            recoveredCount += 1
        }
        if !failedStarts.isEmpty {
            // Без надгробий: удалять нечего — файлов нет, — а камень без файла
            // всё равно ушёл бы на первом же скане.
            NSLog("[RecordingStore] Убрано пустых стартов: \(failedStarts.count)")
            recordings.removeAll { failedStarts.contains($0.id) }
        }
        if recoveredCount > 0 || !failedStarts.isEmpty { save() }
        return recoveredCount
    }

    /// Rebuild `<id>.wav` from surviving `.mic` / `.sys` stems after a hard quit (C3).
    @discardableResult
    func recoverMissingFinalMixes() async -> Int {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        var rebuilt = 0
        for i in recordings.indices {
            let finalURL = dir.appendingPathComponent(recordings[i].filename)
            if FileManager.default.fileExists(atPath: finalURL.path) { continue }
            let stems = AudioSourceStemURLs.expectedSiblings(for: finalURL)
            guard FileManager.default.fileExists(atPath: stems.microphoneURL.path) else { continue }
            let sysURL = FileManager.default.fileExists(atPath: stems.systemURL.path)
                ? stems.systemURL : nil
            await AudioRecorder.produceFinalMix(
                micURL: stems.microphoneURL,
                sysURL: sysURL,
                finalURL: finalURL,
                systemStemOffset: recordings[i].systemStemOffset ?? 0
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                let dur = Self.wavDuration(url: finalURL)
                if dur > 0 { recordings[i].duration = dur }
                rebuilt += 1
            }
        }
        if rebuilt > 0 { save() }
        return rebuilt
    }

    // MARK: - Orphan Scanning

    /// Подобрать записи, которые есть на диске и которых нет в индексе.
    ///
    /// Раньше это было событием запуска, и только его. Значит, wav, появившийся
    /// при живом приложении, не существовал для него до перезапуска — а
    /// перезапустить его мог только человек, который и не должен знать, что
    /// такое бывает. Теперь скан зовут ещё и когда воркер собирается сказать
    /// «всё сделано» (`AppState.adoptOrphans`): это самый дешёвый момент, чтобы
    /// ошибиться в другую сторону, и самый дорогой, чтобы ошибиться в эту.
    ///
    /// Возвращает, сколько встреч подобрано, — вызывающая сторона обязана после
    /// ненулевого ответа пнуть пайплайн, иначе подобранная встреча просто
    /// полежит в списке необработанной.
    ///
    /// - Parameter undoableID: встреча, чьё «Вернуть» ещё на экране. Её аудио
    ///   трогать нельзя: отмена, которая не может вернуть звук, — не отмена.
    @discardableResult
    func scanForOrphanRecordings(undoableID: String? = nil) -> Int {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return 0 }

        var changed = false
        var adopted = 0
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"

        var wavs: [String: URL] = [:]
        for file in files where file.pathExtension == "wav" {
            let id = file.deletingPathExtension().lastPathComponent
            if id.hasSuffix(".mic") || id.hasSuffix(".sys") { continue }
            wavs[id] = file
        }

        // Надгробие, у которого след ещё на месте, значит удаление не довели до
        // конца. Довести сейчас — иначе оно лежит на диске вечно: в списке его
        // нет, в подсчёте размера библиотеки нет (там проход по индексу), и
        // предъявить его человеку негде. Замерено 2026-08-09: 24 МБ от одной
        // удалённой встречи пережили штатный выход приложения.
        //
        // Раньше здесь дочищалось только аудио, а расшифровка и конспект
        // оставались всегда. Теперь дочистка — то же стирание, что и по кнопке
        // (`ArchiveEraser`), поэтому виды следов перечислены в одном месте, а не
        // в двух, которые разъедутся.
        //
        // Это и делает надгробие самоубирающимся: следы уходят, следом уходит
        // камень, и `deleted.json` не превращается в список всего, что человек
        // когда-либо удалил.
        let finished = ArchiveEraser.finishPendingErasures(in: layout, keeping: undoableID)
        if !finished.isEmpty {
            NSLog("[RecordingStore] Дочищено незакрытых удалений: \(finished.count)")
            for id in finished { wavs.removeValue(forKey: id) }
        }
        loadTombstones()

        let adoptableIDs = OrphanAdoption.adoptable(
            fileIDs: Array(wavs.keys),
            knownIDs: Set(recordings.map(\.id)),
            tombstoned: Set(tombstones.map(\.id))
        )
        for id in adoptableIDs {
            guard let file = wavs[id] else { continue }
            let date = df.date(from: id) ?? ((try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date())
            recordings.append(RecordingEntry(
                id: id, filename: file.lastPathComponent, date: date,
                duration: Self.wavDuration(url: file), title: id,
                status: .recorded, transcript: nil
            ))
            changed = true
            adopted += 1
        }
        if adopted > 0 {
            NSLog("[RecordingStore] Подобрано записей с диска: \(adopted)")
        }

        // Fill in missing durations
        for i in recordings.indices where recordings[i].duration == 0 {
            let url = dir.appendingPathComponent(recordings[i].filename)
            let dur = Self.wavDuration(url: url)
            if dur > 0 { recordings[i].duration = dur; changed = true }
        }

        if changed {
            recordings.sort { $0.date > $1.date }
            save()
        }
        return adopted
    }

    // MARK: - WAV Duration

    static func wavDuration(url: URL) -> Double {
        WavHeader.duration(url: url)
    }
}
