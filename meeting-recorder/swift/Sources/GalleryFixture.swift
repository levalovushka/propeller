#if GALLERY
import Foundation
import PropellerPure

/// # A throwaway archive the gallery poses instead of the real one
///
/// The first export produced twenty-one byte-identical PNGs out of forty-one and
/// still looked like a working reference. The cause was not the poser: it was
/// that a fabricated `RecordingEntry` is not enough to make a screen render its
/// content. The summary reads a markdown file (`AppState.resolvedRecapURL`), the
/// letter reads another one, the transcript reads the entry's own segment
/// snapshot — and with none of those present, twelve different states all drew
/// their empty variant: "Саммари — конспект" and "Саммари — правка" were the same
/// photograph of "Нет саммари".
///
/// So the fixture is a real archive in a temp directory: real files, real index,
/// read through the app's own code paths. Nothing is simulated, which is the
/// same reason the exporter photographs a real window instead of using
/// `ImageRenderer`.
///
/// # Why not the user's archive
///
/// The library screens used to photograph whatever meetings the machine happened
/// to hold. That is unreproducible — "список встреч — пусто" showed six
/// meetings — and it puts someone's actual meeting titles into a Figma file the
/// team can open. Both are fixed by owning the data.
///
/// # Safety
///
/// `Preferences.galleryArchiveRoot` is set before `AppState` exists, so every
/// read *and* every write in the process lands in the temp directory. The real
/// archive is not opened, let alone modified, and the worker is frozen
/// (`AppState.galleryFrozen`) so it never tries to transcribe a meeting that has
/// no audio behind it.
@MainActor
enum GalleryFixture {

    /// Opt in for the interactive gallery window; `--gallery-export` implies it.
    static let flag = "--gallery-fixtures"

    private(set) static var root: URL?

    /// True once the archive has been redirected. `AppState` asks at init so it
    /// can freeze the worker before `bootstrap()` hands it fixture meetings.
    static var isActive: Bool { root != nil }

    // MARK: - Install

    /// Must run before `AppState` is built — `RecordingStore` reads its index
    /// during init, and a store pointed at the real archive stays pointed there.
    static func installIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(flag) || args.contains(GalleryExport.launchFlag) else { return }
        install()
    }

    private static func install() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-gallery-\(ProcessInfo.processInfo.processIdentifier)")
        let fm = FileManager.default
        for sub in ["recordings", "meetings"] {
            try? fm.createDirectory(at: dir.appendingPathComponent(sub),
                                    withIntermediateDirectories: true)
        }
        Preferences.galleryArchiveRoot = dir.path
        root = dir

        let meetings = dir.appendingPathComponent("meetings")
        // Name by prefix + suffix only: that is all `RecapFile.isRecap` and the
        // follow-up lookup match on, so no slug has to be kept in sync.
        // Every posed meeting that claims to be summarised gets a summary on disk.
        //
        // Only `contentID` used to get one, so «Всё готово» photographed a row at
        // `.summarized` beside a pane saying «Саммари пока нет» — a state the app
        // cannot be in (`RecordingStore.reconcileSummarizedStage` demotes a
        // meeting whose recap file is missing, invariant I9). The fixture was the
        // only thing that could produce it, and a reference of an impossible state
        // is worse than a missing one.
        for entry in allFixtureEntries where entry.status >= .summarized {
            try? recapMarkdown.write(
                to: meetings.appendingPathComponent("\(entry.id)-recap.md"),
                atomically: true, encoding: .utf8
            )
        }

        for (id, duration) in audioRoster {
            writeSilentWav(id: id, duration: duration, into: dir.appendingPathComponent("recordings"))
        }
        NSLog("[GalleryFixture] archive at \(dir.path)")
    }

    /// Every meeting any frame can pose, deduplicated. One list so audio, recap
    /// files and rows are all derived from the same set — a screen invented in one
    /// place and forgotten in another is how the fixture lied about «Всё готово».
    private static var allFixtureEntries: [RecordingEntry] {
        var seen = Set<String>()
        var out: [RecordingEntry] = []
        func add(_ entry: RecordingEntry) {
            guard seen.insert(entry.id).inserted else { return }
            out.append(entry)
        }
        library.forEach(add)
        UIStateCatalog.meetingStates.map(pipelineEntry(for:)).forEach(add)
        UIStateCatalog.detailTabs.map { tabEntry(for: $0.id) }.forEach(add)
        UIStateCatalog.recording.map { recordingEntry(for: $0.id) }.forEach(add)
        return out
    }

    /// Every fixture meeting, with the length its row claims. Derived from the
    /// entries themselves so a new screen cannot get audio that disagrees with
    /// its own duration.
    private static var audioRoster: [(String, Double)] {
        allFixtureEntries.map { ($0.id, $0.duration) }
    }

    /// Silence, sized to the meeting it belongs to.
    ///
    /// Not decoration: «Расшифровать» in the empty transcript
    /// panel are gated on `entry.audioFileExists`, so with no file behind them
    /// "Транскрипт — пусто" and "Транскрипт — ошибка" photographed as the same
    /// empty panel. The file is sparse — a 44-byte header and a hole — so an
    /// hour of silence costs a header's worth of disk.
    private static func writeSilentWav(id: String, duration: Double, into dir: URL) {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let blockAlign = UInt16(Int(channels) * Int(bits) / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(max(0, duration)) * byteRate

        var header = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36) + dataSize)
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))                 // PCM chunk size
        put(UInt16(1))                  // PCM
        put(channels)
        put(sampleRate)
        put(byteRate)
        put(blockAlign)
        put(bits)
        header.append(contentsOf: Array("data".utf8))
        put(dataSize)

        let url = dir.appendingPathComponent("\(id).wav")
        try? header.write(to: url)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.truncate(atOffset: UInt64(44) + UInt64(dataSize))
        try? handle.close()
    }

    // MARK: - Posing

    /// Ephemeral app state this screen needs. Everything a screen can read is
    /// set here — store contents, selection, tab, activity — so no frame
    /// inherits a leftover from the one before it.
    static func pose(id: String, state: AppState) {
        reset(state)

        if let meeting = UIStateCatalog.meetingStates.first(where: { $0.id == id }) {
            poseMeeting(meeting, state: state)
            return
        }
        if id.hasPrefix("tab-") {
            poseTab(id, state: state)
            return
        }
        if id.hasPrefix("rec-") {
            poseRecording(id, state: state)
            return
        }
        switch id {
        case "lib-empty":
            state.recordingStore.recordings = []
        case "lib-deleted":
            // Soft-delete pose: out of the list, no «Вернуть» row. Same shape
            // as a real delete after dissolve.
            if let victim = library.first {
                state.recordingStore.recordings = Array(library.dropFirst())
                state.galleryPoseDeletion(victim)
                state.selectedRecordingID = library.dropFirst().first?.id
            }
        case "rail-prompt-calendar":
            state.galleryPoseSetupPrompt(.calendar)
        case "rail-prompt-name":
            state.galleryPoseSetupPrompt(.name)
        default:
            break                       // lib-populated / lib-search / setup
        }
    }

    private static func reset(_ state: AppState) {
        state.galleryFrozen = true
        state.isRecording = false
        state.galleryPoseRecording(nil)
        state.galleryPosePaused(false)
        state.live.end()
        state.galleryPose(activity: .idle)
        state.galleryEditingRecap = false
        state.galleryRewritingSummary = false
        state.galleryRecapModelOverride = nil
        state.selectedRecordingID = nil
        // Not nil: the pane keeps whatever column it was last switched to, so a
        // frame that asks for nothing has to ask for the default explicitly —
        // otherwise the shot depends on which frame ran before it.
        state.preferredDetailTab = "recap"
        state.pipelineError = nil
        state.galleryPoseDeletion(nil)
        state.galleryPoseMicDenied(false)
        state.galleryPoseSetupPrompt(nil)
        state.recordingStore.recordings = library
    }

    private static func poseMeeting(_ meeting: UIStateCatalog.MeetingState, state: AppState) {
        let posed = pipelineEntry(for: meeting)
        var rows = library
        rows.insert(posed, at: 0)
        state.recordingStore.recordings = rows

        switch meeting.involvement {
        case .idle:
            state.galleryPose(activity: .idle)
        case .working(let phase):
            state.galleryPose(activity: .working(recordingID: posed.id, phase: phase, detail: nil))
        case .elsewhere(let phase):
            // Deliberately a different meeting: this row must stay static while
            // the worker is busy elsewhere, and the neighbour must show it is.
            state.galleryPose(activity: .working(recordingID: rows[1].id, phase: phase, detail: nil))
        }

        if meeting.stage == .recording {
            state.isRecording = true
            state.galleryPoseRecording(posed.id)
            state.selectedRecordingID = posed.id
            state.elapsedString = "12:38"
            state.elapsedSeconds = 758
        }
        // A meeting with nothing left to do says so on its own row and in its
        // card — the resting reason, not an error and not a button
        // (`design/no-dead-ends.md`).
    }

    /// Экран записи: живой транскрипт и он же на паузе.
    ///
    /// Реплики набираются теми же методами, что и настоящие — движка тут нет, а
    /// правило склейки должно остаться тем же, иначе кадр показывает не то, что
    /// увидит человек.
    private static func poseRecording(_ id: String, state: AppState) {
        let entry = recordingEntry(for: id)
        state.recordingStore.recordings = [entry] + library
        state.selectedRecordingID = entry.id
        state.isRecording = true
        state.galleryPoseRecording(entry.id)
        state.elapsedString = "12:38"
        state.elapsedSeconds = 758

        var live = LiveTranscript()
        live.absorb(channel: .owner, start: 731, end: 734,
                         text: "Давай пройдёмся по вебхукам.")
        live.absorb(channel: .remote, start: 736, end: 740,
                         text: "Да, у нас там подпись не сходится на ретраях.")
        live.absorb(channel: .owner, start: 742, end: 745,
                         text: "Значит считаем её от исходного тела, а не от повторного.")
        if id == "rec-live" {
            live.absorb(channel: .remote, start: 754, end: 757,
                        text: "Тогда я поправлю клиент и прогоню ретраи ещё раз.")
        }
        state.live.galleryPose(recordingID: entry.id, transcript: live)
        if id == "rec-paused" { state.galleryPosePaused(true) }
    }

    private static func poseTab(_ id: String, state: AppState) {
        let entry = tabEntry(for: id)
        state.recordingStore.recordings = [entry] + library.filter { $0.id != entry.id }
        state.selectedRecordingID = entry.id
        state.preferredDetailTab = tabPreference(for: id)

        switch id {
        case "tab-summary-empty-nomodel": state.galleryRecapModelOverride = true
        case "tab-summary-empty-ready":   state.galleryRecapModelOverride = false
        case "tab-summary-editing":       state.galleryEditingRecap = true
        case "tab-summary-rewriting":
            state.galleryEditingRecap = true
            state.galleryRewritingSummary = true
        case "tab-transcript-failed":
            // The panel prints the *app's* current error, not the entry's own
            // record of it — which is how a real failure reaches this screen.
            // The panel prints the app's current error only for hand actions now;
            // a resting meeting states its reason instead.
            state.pipelineError = nil
        default: break
        }
    }

    /// `DetailTab.followUp` is the letter's raw value. Posing "letter" here was
    /// the whole reason that frame photographed the summary tab instead.
    private static func tabPreference(for id: String) -> String? {
        if id.hasPrefix("tab-summary")    { return "recap" }
        if id.hasPrefix("tab-notes")      { return "notes" }
        if id.hasPrefix("tab-transcript") { return "transcript" }
        return nil
    }

    // MARK: - The cast

    /// The meeting that owns the content files. Everything with something to
    /// read — summary, letter, transcript, notes — is this one.
    static let contentID = "gal-workshop"

    static var library: [RecordingEntry] {
        [
            make(id: contentID, title: "Агентный дизайн",
                 at: today(15, 10), duration: 4_320, stage: .summarized,
                 topics: ["дизайн-язык вместо дизайн-системы", "чистые эксперименты"],
                 tags: ["планирование"], segments: true),
            make(id: "gal-sync", title: "Синк по релизу 1.14",
                 at: today(12, 40), duration: 1_320, stage: .summarized,
                 topics: ["сроки", "регресс", "сборка"], segments: true),
            make(id: "gal-interview", title: "Интервью: продуктовый дизайнер",
                 at: today(10, 20), duration: 3_660, stage: .summarized,
                 topics: ["портфолио", "процесс найма"], segments: true),
            make(id: "gal-1on1", title: "Один на один",
                 at: yesterday(19, 30), duration: 1_860, stage: .summarized,
                 topics: ["нагрузка", "отпуск"], segments: true),
            make(id: "gal-quarter", title: "Планирование квартала",
                 at: yesterday(11, 0), duration: 4_440, stage: .summarized,
                 topics: ["цели", "найм", "бюджет"], segments: true),
            make(id: "gal-review", title: "Дизайн-ревью корпуса",
                 at: daysAgo(3, 16, 0), duration: 2_700, stage: .summarized,
                 topics: ["каноны", "примеры"], segments: true),
        ]
    }

    /// The meeting the pipeline states are about. Newest, so it sits at the top
    /// of «Сегодня» where the row being described is the first thing seen.
    private static func pipelineEntry(for meeting: UIStateCatalog.MeetingState) -> RecordingEntry {
        make(
            id: "gal-\(meeting.id)",
            title: "Созвон по интеграции",
            at: today(16, 5),
            duration: meeting.stage == .recording ? 758 : 1_705,
            stage: meeting.stage,
            // Topics are LLM-derived from the finished summary, so a meeting
            // that has not been summarised yet has no subtitle. Faking one here
            // would draw a row that cannot exist.
            topics: meeting.stage >= .summarized ? ["интеграция", "вебхуки"] : nil,
            segments: meeting.stage >= .transcribed,
            // `kind` is stated, not inferred: this screen only exists for a
            // failure with nothing left to try.
            failure: meeting.hasFailure
                // The only shape a person can still see: there was no speech in
                // the recording. Posed explicitly rather than left to
                // classification — a fixture that guessed would quietly stop
                // posing this screen the day the message changed.
                ? PipelineFailure(phase: .transcribing,
                                  message: MeetingRest.TerminalReason.noSpeech.logMessage,
                                  kind: .terminal, terminalReason: .noSpeech)
                : nil
        )
    }

    /// Встреча, которая «пишется» на кадрах экрана записи.
    static func recordingEntry(for id: String) -> RecordingEntry {
        make(
            id: "gal-\(id)", title: "Созвон по интеграции",
            at: today(16, 5), duration: 758, stage: .recording,
            notes: "Проверить подпись вебхука на ретраях"
        )
    }

    static func tabEntry(for id: String) -> RecordingEntry {
        switch id {
        case "tab-summary-empty-nomodel", "tab-summary-empty-ready":
            return make(id: "gal-summary-empty", title: "Синк по релизу 1.14",
                        at: today(12, 40), duration: 1_320, stage: .saved, segments: true)
        case "tab-notes-empty":
            return make(id: "gal-notes-empty", title: "Один на один",
                        at: yesterday(19, 30), duration: 1_860, stage: .summarized,
                        topics: ["нагрузка", "отпуск"], segments: true, notes: nil)
        case "tab-transcript-empty":
            return make(id: "gal-transcript-empty", title: "Созвон по интеграции",
                        at: today(16, 5), duration: 1_705, stage: .recorded)
        case "tab-transcript-failed":
            return make(id: "gal-transcript-failed", title: "Созвон по интеграции",
                        at: today(16, 5), duration: 1_705, stage: .recorded,
                        // Retries do not run out any more, so the only way this
                        // panel is reachable is an input with nothing in it.
                        failure: PipelineFailure(
                            phase: .transcribing,
                            message: MeetingRest.TerminalReason.noSpeech.logMessage,
                            kind: .terminal, terminalReason: .noSpeech))
        default:
            // Summary content / editing, letter, notes, transcript — the one
            // meeting with files behind it.
            return library[0]
        }
    }

    private static func make(
        id: String,
        title: String,
        at date: Date,
        duration: Double,
        stage: RecordingStage,
        topics: [String]? = nil,
        tags: [String]? = nil,
        segments: Bool = false,
        notes: String? = "созвониться с подрядчиком\nпроверить бюджет к пятнице",
        failure: PipelineFailure? = nil
    ) -> RecordingEntry {
        RecordingEntry(
            id: id,
            filename: "\(id).wav",
            date: date,
            duration: duration,
            title: title,
            status: stage,
            transcript: segments ? transcriptText : nil,
            notes: notes,
            language: "ru",
            mergedSegmentsJSON: segments ? segmentsJSON : nil,
            topics: topics,
            tags: tags,
            lastFailure: failure
        )
    }

    private static func today(_ hour: Int, _ minute: Int) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private static func yesterday(_ hour: Int, _ minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func tomorrow(_ hour: Int, _ minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func daysAgo(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: - Content

    private static let segmentList: [PersistedSegment] = [
        .init(index: 0, startTime: 0, endTime: 11,
              text: "Давайте начнём. Сегодня разбираем скоуп дизайн-системы под веб.",
              speaker: "Левон"),
        .init(index: 1, startTime: 12, endTime: 19,
              text: "У меня вопрос по срокам — успеваем к понедельнику?",
              speaker: "Speaker 2"),
        .init(index: 2, startTime: 19, endTime: 31,
              text: "Успеваем, если сегодня закроем компоненты и заведём сторибук.",
              speaker: "Левон"),
        .init(index: 3, startTime: 31, endTime: 44,
              text: "Тогда я беру на себя токены, а ревью назначим на четверг.",
              speaker: "Speaker 3"),
        .init(index: 4, startTime: 45, endTime: 58,
              text: "По боту: осталась выкладка и текст первого сообщения.",
              speaker: "Speaker 2"),
        .init(index: 5, startTime: 58, endTime: 72,
              text: "Текст я пришлю сегодня вечером, выкладку делаем завтра утром.",
              speaker: "Левон"),
        .init(index: 6, startTime: 73, endTime: 86,
              text: "И надо решить, что делаем с корпусом — он всё ещё в черновике.",
              speaker: "Speaker 3"),
        .init(index: 7, startTime: 86, endTime: 99,
              text: "Оставляем в черновике до релиза, иначе не успеем ни то, ни другое.",
              speaker: "Левон"),
    ]

    private static let segmentsJSON: String = {
        guard let data = try? JSONEncoder().encode(segmentList),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }()

    private static let transcriptText: String = segmentList
        .map { "**\($0.speaker)** · \(Self.stamp($0.startTime))\n\($0.text)" }
        .joined(separator: "\n\n")

    private static func stamp(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private static let recapMarkdown = """
    ## Итог

    Разбирали, где в вебе агент действительно заменяет руки, а где только делает вид. Сошлись на том, что дело не в размере дизайн-системы, а в подготовке конкретного проекта: прототип, контент и десяток правил под него. Договорились проверить это на двух живых проектах и сравнить результат.

    ## Заметки

    - 14:20 — проверить, сколько итераций уходит на один блок
    - 51:05 — вопрос Марине: кто вычитывает то, что агент нарисовал

    ## Решения

    - Отказались от общей дизайн-системы на все проекты. Вместо неё — «дизайн-язык»: 5–10 правил, написанных под один проект, поверх токенов.
    - Прототип и контент готовит дизайнер, до того как за макет берётся агент. Костя: «без этого на выходе будет каша, я проверял дважды».
    - Адаптив на этой неделе не трогаем. Сначала десктоп и чистый прогон.
    - Каждый ведёт по одному эксперименту и приносит его целиком — со всеми промахами, а не только удачный кадр.

    ## Задачи

    - **Марина** — собрать 5–10 референсов и список уникальных блоков для «Меркурия». К четвергу, на дейлик.
    - **Костя** — прогнать главную «Меркурия» через агента, считая итерации на блок.
    - **Левон** — описать дизайн-язык версии 1.0: что в нём есть и чего в нём принципиально нет.

    ## Открытые вопросы

    - Кто вычитывает результат агента и по какому критерию — договорённости нет.
    - Считать ли скорость выигрышем, если правок на выходе больше, чем экономии.
    """
}
#endif
