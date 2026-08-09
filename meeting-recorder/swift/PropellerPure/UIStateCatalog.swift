import Foundation

/// Every state the UI is allowed to be in, as data.
///
/// This is the redesign reference and the gallery's index in one place. It is
/// here rather than next to the views for the usual reason: `Sources/` is an
/// executable target, so a catalogue living there could not be checked. Here a
/// test can prove the list actually covers the type — forget a case when adding
/// a stage and the test goes red instead of the gap turning up mid-redesign.
///
/// The meeting rows mirror `docs/REFACTOR-PIPELINE-STATE.md` §5 one-for-one.
/// That table is the specification; this is the machine-readable copy.
public enum UIStateCatalog {

    // MARK: - Meeting states

    /// How the pipeline relates to *this* meeting. Narrower than
    /// `PipelineActivity`, which also carries the id of whatever is running:
    /// for a screenshot the only thing that matters is whether the work is
    /// ours, someone else's, or absent.
    public enum Involvement: Equatable, Sendable {
        case idle
        /// The worker is on this meeting.
        case working(PipelineActivity.Phase)
        /// The worker is on a different meeting — this one must look static.
        case elsewhere(PipelineActivity.Phase)
    }

    public struct MeetingState: Equatable, Sendable, Identifiable {
        /// Stable slug. Used for screenshot filenames and Figma frame names, so
        /// a re-shoot replaces the old frame instead of piling up next to it.
        public let id: String
        /// What a person sees, in their words — the column from §5.
        public let label: String
        public let stage: RecordingStage
        public let involvement: Involvement
        public let hasFailure: Bool

        public init(
            id: String,
            label: String,
            stage: RecordingStage,
            involvement: Involvement,
            hasFailure: Bool = false
        ) {
            self.id = id
            self.label = label
            self.stage = stage
            self.involvement = involvement
            self.hasFailure = hasFailure
        }
    }

    /// The eleven legal states. Anything not here should be unrepresentable.
    public static let meetingStates: [MeetingState] = [
        .init(id: "01-recording",      label: "Идёт запись, таймер",
              stage: .recording,      involvement: .idle),
        .init(id: "02-queued-asr",     label: "В очереди на расшифровку",
              stage: .recorded,       involvement: .idle),
        .init(id: "03-transcribing",   label: "Прогресс расшифровки",
              stage: .recorded,       involvement: .working(.transcribing)),
        .init(id: "04-queued-diarize", label: "В очереди на диаризацию",
              stage: .transcribedRaw, involvement: .idle),
        .init(id: "05-diarizing",      label: "«Определяем спикеров…»",
              stage: .transcribedRaw, involvement: .working(.diarizing)),
        // Two stages, one appearance, and that is the honest picture: «текст в
        // индексе» and «файл на диске» differ only inside the app, and both read
        // as «саммари в очереди». Kept as two frames so every stage is covered;
        // the exporter reports them as identical, which they are.
        .init(id: "06-transcript-ready", label: "Транскрипт готов, саммари в очереди",
              stage: .transcribed,    involvement: .idle),
        .init(id: "07-queued-recap",   label: "Файл записан, саммари в очереди",
              stage: .saved,          involvement: .idle),
        .init(id: "08-summarizing",    label: "«Генерируем саммари…»",
              stage: .saved,          involvement: .working(.summarizing)),
        .init(id: "09-done",           label: "Всё готово",
              stage: .summarized,     involvement: .idle),
        .init(id: "10-other-busy",     label: "Работа идёт над другой встречей — здесь спиннера нет",
              stage: .saved,          involvement: .elsewhere(.summarizing)),
        .init(id: "11-failed",         label: "Дальше нечего делать — аудио удалено",
              stage: .transcribedRaw, involvement: .idle, hasFailure: true),
    ]

    /// Reachable only by crashing mid-ASR; `RecordingRecovery` resolves it on
    /// launch, so it has no screen of its own and §5 does not list it. Named
    /// explicitly so the coverage test can tell "deliberately absent" from
    /// "forgotten".
    public static let stagesWithoutOwnScreen: Set<RecordingStage> = [.transcribing]

    /// Phases with no screen of their own, for the same reason: `.saving` writes
    /// the markdown inside the summarising job and is never scheduled alone
    /// (`RecordingStage.nextPhase`). It used to have a state — «Транскрипт виден,
    /// идёт сохранение» — which is one frame of a file write between two real
    /// steps, and nobody has ever needed to look at it.
    public static let phasesWithoutOwnScreen: Set<PipelineActivity.Phase> = [.saving]

    // MARK: - Other surfaces

    /// Screens outside the pipeline. No type to derive these from, so the list
    /// is hand-kept — but it is still one list rather than tribal knowledge.
    public struct Screen: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    /// Настройка — одна плашка вместо шести.
    ///
    /// Ушли: карусель на четыре слайда, экран имени, экран календаря, экран про
    /// модель саммари и «Готово». Первый описывал приложение тому, кто его только
    /// что поставил; предпоследний объявлял загрузку, которая идёт сама; последний
    /// существовал, чтобы его закрыли. Имя и календарь ничего не держат и теперь
    /// спрашиваются из рельса — их состояния ниже, в `railPrompt`.
    ///
    /// Осталось три кадра: что видит человек до единственного разрешения, что
    /// после микрофона и что после обоих. Запуск при входе — переключатель, а не
    /// разрешение: он не может быть «выдан кем-то ещё», и отдельного кадра ему не
    /// нужно.
    public static let onboarding: [Screen] = [
        .init(id: "onb-01-setup",              label: "Настройка — ничего не выдано"),
        .init(id: "onb-01-setup-mic",          label: "Настройка — микрофон есть"),
        .init(id: "onb-01-setup-all",          label: "Настройка — всё выдано"),
    ]

    /// Блок у подошвы рельса — то, что настройка не стала спрашивать экраном.
    ///
    /// Оба шага живут в приложении, поверх списка встреч, поэтому их кадры — это
    /// кадры рельса, а не плашки. Снимаются в окне: вопрос, на который они
    /// отвечают, — «не спорит ли блок со списком под ним».
    public static let railPrompt: [Screen] = [
        .init(id: "rail-prompt-calendar", label: "Рельс — «Подключите календарь» 1/2"),
        .init(id: "rail-prompt-name",     label: "Рельс — «Как вас зовут?» 2/2"),
    ]

    /// Экран идущей записи.
    ///
    /// Отдельным списком, а не строками в `meetingStates`: пауза — не стадия
    /// (её нет в `RecordingStage` и не должно быть: стадия — это чего встреча
    /// достигла), а живой транскрипт — не состояние пайплайна вовсе. Стадия
    /// `.recording` свой кадр имеет, `01-recording`, и это первая секунда, когда
    /// ещё ничего не сказано.
    public static let recording: [Screen] = [
        .init(id: "rec-live",   label: "Запись — живой транскрипт"),
        .init(id: "rec-paused", label: "Запись — пауза"),
    ]

    public static let detailTabs: [Screen] = [
        .init(id: "tab-summary-empty-nomodel", label: "Саммари — пусто, модель не скачана"),
        .init(id: "tab-summary-empty-ready",   label: "Саммари — пусто, модель есть"),
        .init(id: "tab-summary-content",       label: "Саммари — конспект"),
        .init(id: "tab-summary-editing",       label: "Саммари — правка"),
        .init(id: "tab-summary-rewriting",     label: "Саммари — модель переписывает фрагмент"),
        .init(id: "tab-transcript-empty",      label: "Транскрипт — пусто"),
        .init(id: "tab-transcript-content",    label: "Транскрипт — есть"),
        .init(id: "tab-transcript-failed",     label: "Транскрипт — дальше нечего делать"),
    ]

    public static let library: [Screen] = [
        // Слаг остаётся прежним намеренно: по нему переснимок заменяет кадр в
        // Figma. Подпись — новая, потому что пустой архив больше не «список без
        // строк», а `FirstRunView` вместо обеих колонок.
        .init(id: "lib-empty",     label: "Пустой архив — «Запишем первую встречу?»"),
        .init(id: "lib-populated", label: "Список встреч — записи по секциям"),
        .init(id: "lib-search",    label: "Поиск ⌘K"),
        // After dissolve: the row is gone; restore is ⌘Z, not a list state.
        .init(id: "lib-deleted",   label: "Список встреч — после удаления"),
    ]

    /// Everything the gallery has to be able to show, in shooting order.
    public static var allScreenIDs: [String] {
        meetingStates.map(\.id)
            + (recording + onboarding + railPrompt + detailTabs + library).map(\.id)
    }
}
