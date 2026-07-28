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
        .init(id: "06-saving",         label: "Транскрипт виден, идёт сохранение",
              stage: .transcribed,    involvement: .working(.saving)),
        .init(id: "07-queued-recap",   label: "Транскрипт готов, саммари в очереди",
              stage: .saved,          involvement: .idle),
        .init(id: "08-summarizing",    label: "«Генерируем саммари…»",
              stage: .saved,          involvement: .working(.summarizing)),
        .init(id: "09-done",           label: "Всё готово",
              stage: .summarized,     involvement: .idle),
        .init(id: "10-other-busy",     label: "Работа идёт над другой встречей — здесь спиннера нет",
              stage: .saved,          involvement: .elsewhere(.summarizing)),
        .init(id: "11-failed",         label: "Ошибка + кнопка «Повторить»",
              stage: .transcribedRaw, involvement: .idle, hasFailure: true),
    ]

    /// Reachable only by crashing mid-ASR; `RecordingRecovery` resolves it on
    /// launch, so it has no screen of its own and §5 does not list it. Named
    /// explicitly so the coverage test can tell "deliberately absent" from
    /// "forgotten".
    public static let stagesWithoutOwnScreen: Set<RecordingStage> = [.transcribing]

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

    public static let onboarding: [Screen] = [
        .init(id: "onb-01-welcome",            label: "Приветствие"),
        .init(id: "onb-02-name",               label: "Имя"),
        .init(id: "onb-03-calendar",           label: "Календарь — не подключён"),
        .init(id: "onb-03-calendar-granted",   label: "Календарь — подключён"),
        .init(id: "onb-04-permissions",        label: "Разрешения — ничего не выдано"),
        .init(id: "onb-04-permissions-partial", label: "Разрешения — микрофон есть, экрана нет"),
        .init(id: "onb-04-permissions-all",    label: "Разрешения — всё выдано"),
        .init(id: "onb-05-model",              label: "Модель саммари — предложение"),
        .init(id: "onb-05-model-downloading",  label: "Модель саммари — качается"),
        .init(id: "onb-05-model-ready",        label: "Модель саммари — готова"),
        .init(id: "onb-05-model-error",        label: "Модель саммари — ошибка установки"),
        .init(id: "onb-06-end",                label: "Готово"),
    ]

    public static let detailTabs: [Screen] = [
        .init(id: "tab-summary-empty-nomodel", label: "Саммари — пусто, модель не скачана"),
        .init(id: "tab-summary-empty-ready",   label: "Саммари — пусто, модель есть"),
        .init(id: "tab-summary-content",       label: "Саммари — конспект"),
        .init(id: "tab-summary-editing",       label: "Саммари — правка"),
        .init(id: "tab-letter",                label: "Письмо"),
        .init(id: "tab-notes-empty",           label: "Заметки — пусто"),
        .init(id: "tab-notes-content",         label: "Заметки — есть"),
        .init(id: "tab-transcript-empty",      label: "Транскрипт — пусто"),
        .init(id: "tab-transcript-content",    label: "Транскрипт — есть"),
        .init(id: "tab-transcript-failed",     label: "Транскрипт — ошибка + «Повторить»"),
    ]

    public static let library: [Screen] = [
        .init(id: "lib-empty",     label: "Список встреч — пусто"),
        .init(id: "lib-populated", label: "Список встреч — записи по секциям"),
        .init(id: "lib-upcoming",  label: "Список встреч — с блоком Upcoming"),
        .init(id: "lib-search",    label: "Поиск ⌘K"),
    ]

    public static let toasts: [Screen] = [
        .init(id: "toast-mic",     label: "Нужен микрофон"),
        .init(id: "toast-disk",    label: "Мало места на диске"),
        .init(id: "toast-storage", label: "Библиотека разрослась"),
        .init(id: "toast-failure", label: "Не удалось обработать + «Повторить»"),
    ]

    /// Everything the gallery has to be able to show, in shooting order.
    public static var allScreenIDs: [String] {
        meetingStates.map(\.id) + (onboarding + detailTabs + library + toasts).map(\.id)
    }
}
