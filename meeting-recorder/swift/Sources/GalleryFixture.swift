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
/// their empty variant. "Саммари — конспект", "Саммари — правка" and "Письмо"
/// were the same photograph of "Нет саммари".
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
        try? recapMarkdown.write(to: meetings.appendingPathComponent("\(contentID)-recap.md"),
                                 atomically: true, encoding: .utf8)
        try? letterMarkdown.write(to: meetings.appendingPathComponent("\(contentID)-followup.md"),
                                  atomically: true, encoding: .utf8)

        for (id, duration) in audioRoster {
            writeSilentWav(id: id, duration: duration, into: dir.appendingPathComponent("recordings"))
        }
        NSLog("[GalleryFixture] archive at \(dir.path)")
    }

    /// Every fixture meeting, with the length its row claims. Derived from the
    /// entries themselves so a new screen cannot get audio that disagrees with
    /// its own duration.
    private static var audioRoster: [(String, Double)] {
        var seen = Set<String>()
        var roster: [(String, Double)] = []
        func add(_ entry: RecordingEntry) {
            guard seen.insert(entry.id).inserted else { return }
            roster.append((entry.id, entry.duration))
        }
        library.forEach(add)
        UIStateCatalog.meetingStates.map(pipelineEntry(for:)).forEach(add)
        UIStateCatalog.detailTabs.map { tabEntry(for: $0.id) }.forEach(add)
        return roster
    }

    /// Silence, sized to the meeting it belongs to.
    ///
    /// Not decoration: «Расшифровать» and «Повторить» in the empty transcript
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
        switch id {
        case "lib-empty":
            state.recordingStore.recordings = []
        case "lib-upcoming":
            CalendarService.shared.upcoming = [upcoming]
        default:
            break                       // lib-populated / lib-search / onboarding / toasts
        }
    }

    private static func reset(_ state: AppState) {
        state.galleryFrozen = true
        state.isRecording = false
        state.galleryPose(activity: .idle)
        state.galleryEditingRecap = false
        state.galleryRecapModelOverride = nil
        state.selectedRecordingID = nil
        state.preferredDetailTab = nil
        state.pipelineError = nil
        // Toasts are screens of their own here; one left standing from an
        // earlier pose would sit on top of an unrelated frame.
        state.showMicPermissionAlert = false
        state.showDiskSpaceAlert = false
        state.showStorageNudgeAlert = false
        state.recordingStore.recordings = library
        CalendarService.shared.upcoming = []
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
            state.elapsedString = "12:38"
            state.elapsedSeconds = 758
        }
        // A failure reaches the user as the toast over the list, which is where
        // «Повторить» lives — the row itself only loses its spinner.
        if let failure = posed.lastFailure { state.pipelineError = failure.message }
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
        case "tab-transcript-failed":
            // The panel prints the *app's* current error, not the entry's own
            // record of it — which is how a real failure reaches this screen.
            state.pipelineError = entry.lastFailure?.message
        default: break
        }
    }

    /// `DetailTab.followUp` is the letter's raw value. Posing "letter" here was
    /// the whole reason that frame photographed the summary tab instead.
    private static func tabPreference(for id: String) -> String? {
        if id.hasPrefix("tab-summary")    { return "recap" }
        if id.hasPrefix("tab-notes")      { return "notes" }
        if id.hasPrefix("tab-transcript") { return "transcript" }
        if id == "tab-letter"             { return "followUp" }
        return nil
    }

    // MARK: - The cast

    /// The meeting that owns the content files. Everything with something to
    /// read — summary, letter, transcript, notes — is this one.
    static let contentID = "gal-workshop"

    static var library: [RecordingEntry] {
        [
            make(id: contentID, title: "Воркшоп по музыке",
                 at: today(15, 10), duration: 2_950, stage: .summarized,
                 topics: ["дизайн-система", "релиз бота", "корпус"],
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
            failure: meeting.hasFailure
                ? PipelineFailure(phase: .diarizing,
                                  message: "gigastt HTTP 413: тело запроса слишком большое")
                : nil
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
                        failure: PipelineFailure(phase: .transcribing,
                                                 message: "gigastt завершился до готовности"))
        default:
            // Summary content / editing, letter, notes, transcript — the one
            // meeting with files behind it.
            return library[0]
        }
    }

    private static var upcoming: UpcomingMeeting {
        // Tomorrow morning, not "now + 40 minutes": always in the future, so
        // auto-record has nothing to act on, and the row reads the same whether
        // the export runs at noon or at midnight.
        let start = tomorrow(10, 30)
        return UpcomingMeeting(
            id: "gal-upcoming",
            title: "Ретро спринта",
            start: start,
            end: start.addingTimeInterval(45 * 60),
            attendees: ["Кирилл", "Аня", "Максим"],
            hasVideoLink: true
        )
    }

    // MARK: - Building blocks

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
    ## О чём договорились

    - Дизайн-система под веб уходит в работу сразу, срок — **понедельник**.
    - Токены берёт на себя третий участник, ревью — в четверг.
    - Корпус остаётся в черновике до релиза: две задачи параллельно команда не вытянет.

    ## Что дальше

    - Закрыть компоненты и завести сторибук — сегодня.
    - Текст первого сообщения бота — сегодня вечером.
    - Выкладка бота — завтра утром.

    ## Открытые вопросы

    - Кто принимает решение по корпусу после релиза.
    """

    private static let letterMarkdown = """
    Привет!

    Коротко по итогам встречи.

    Дизайн-систему под веб начинаем сегодня, ориентир — понедельник. Компоненты
    и сторибук закрываем сегодня, токены на себя берёт Кирилл, ревью назначили
    на четверг.

    По боту: текст первого сообщения пришлю сегодня вечером, выкладка — завтра
    утром. Корпус решили не трогать до релиза, чтобы не растащить команду на две
    задачи сразу.

    Если что-то из этого выглядит иначе с вашей стороны — скажите, поправлю.
    """
}
#endif
