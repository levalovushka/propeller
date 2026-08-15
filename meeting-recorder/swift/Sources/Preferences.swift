import Foundation
import PropellerPure

class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - Transcription

    var domainTerms: String {
        get { defaults.string(forKey: "domainTerms") ?? "" }
        set { defaults.set(newValue, forKey: "domainTerms") }
    }

    /// `domainTerms` parsed into individual phrases for gigastt's hotwords file.
    var domainTermsList: [String] {
        domainTerms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Capture

    /// Пишем ли вторую сторону разговора. Всегда да, и это больше не настройка.
    ///
    /// Она стояла целым разделом «Аудио» и предлагала выключить ровно то, ради
    /// чего записывают встречу: без системного звука в файле остаётся один
    /// микрофон, то есть половина реплик и саммари по половине разговора. Тот же
    /// довод, что снял «Выкл» из провайдеров саммари, — выбор не должен уметь
    /// ломать продукт.
    ///
    /// Стоило это ноль разрешений: дальняя сторона приходит из тапа Core Audio
    /// внутри агрегата на общих часах, а единственное решение TCC на этом пути
    /// оплачено прогревом на старте (`sharedClockCaptureWorks`). Свойство
    /// оставлено на месте, потому что `AudioRecorder` и `CapturePathPolicy`
    /// продолжают спрашивать — просто ответ теперь один. Записанное `false` у
    /// того, кто выключил захват в 1.15, перестаёт читаться: иначе он остался бы
    /// с моно-записями навсегда, без переключателя, которым это вернуть.
    var captureSystemAudio: Bool { true }

    /// Подтверждено ли, что на этой машине работает захват на общих часах
    /// (`ProcessTapCapture`).
    ///
    /// Хранится, потому что выяснять это стоит дорого ровно один раз: первое в
    /// жизни приложения открытие входа Core Audio ждёт решения TCC — замерено,
    /// шестьдесят секунд. Проверять заново на каждом запуске значило бы ещё и
    /// зажигать оранжевый индикатор микрофона каждый раз, когда человек просто
    /// открыл приложение.
    ///
    /// Nil — «ещё не проверяли». Разрешение могут отозвать, поэтому значение
    /// подтверждается заново, если захват не поднялся на живой записи.
    var sharedClockCaptureWorks: Bool? {
        get { defaults.object(forKey: "sharedClockCaptureWorks") as? Bool }
        set { defaults.set(newValue, forKey: "sharedClockCaptureWorks") }
    }

    /// Auto-record on a detected call (any platform in `MeetingPlatform.all`):
    /// off / auto. Default auto: recording starts
    /// automatically and a notification lets the user decline.
    var autoRecordMode: AutoRecordMode {
        get {
            let raw = defaults.string(forKey: "autoRecordMode") ?? ""
            // Migrate the removed "ask" mode to auto (no confirmation prompt).
            if raw == "ask" { return .auto }
            return AutoRecordMode(rawValue: raw) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: "autoRecordMode") }
    }

    // MARK: - Paths

#if GALLERY
    /// Points the whole archive at a throwaway directory for the duration of a
    /// screenshot run (`GalleryFixture`). Set before `AppState` is built and
    /// never cleared — the process exits when the last frame is on disk.
    ///
    /// It exists so posed states can have files behind them without a single
    /// write reaching the real archive, and so no one's actual meeting titles
    /// end up in a Figma file. Absent from shipping builds.
    static var galleryArchiveRoot: String?
#endif

    /// Путь из настроек, приведённый к пригодному виду (`ArchivePath`).
    /// Логика живёт в `PropellerPure`, потому что она решаема без диска, а
    /// цена ошибки — «все встречи пропали» на экране у живого человека.
    private func path(forKey key: String, default fallback: String) -> String {
        ArchivePath.normalized(defaults.string(forKey: key), default: fallback)
    }

    var meetingsPath: String {
        get {
#if GALLERY
            if let root = Preferences.galleryArchiveRoot { return root + "/meetings" }
#endif
            return path(forKey: "meetingsPath", default: defaultMeetingsPath)
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "meetingsPath")
        }
    }

    var recordingsPath: String {
        get {
#if GALLERY
            if let root = Preferences.galleryArchiveRoot { return root + "/recordings" }
#endif
            return path(forKey: "recordingsPath", default: defaultRecordingsPath)
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "recordingsPath")
        }
    }

    /// Path to Obsidian vault directory containing people pages (e.g. wiki/people/).
    /// If empty, wikilink generation for speakers is disabled.
    var peoplePagesPath: String {
        get { defaults.string(forKey: "peoplePagesPath") ?? "" }
        set { defaults.set(newValue, forKey: "peoplePagesPath") }
    }

    // MARK: - Output

    /// Markdown export format. Default is simple (readable, no YAML/wikilinks).
    var markdownOutputFormat: MarkdownOutputFormat {
        get {
            MarkdownOutputFormat(rawValue: defaults.string(forKey: "markdownOutputFormat") ?? "")
                ?? .simple
        }
        set { defaults.set(newValue.rawValue, forKey: "markdownOutputFormat") }
    }

    // MARK: - Recap (LLM)

    var recapProvider: RecapProviderKind {
        get {
            let raw = defaults.string(forKey: "recapProvider") ?? ""
            // Удалённые «Выкл» и «Авто» переезжают на Ollama. Записанное
            // значение **перезаписывается**, а не просто игнорируется на
            // чтении, как это делает миграция `autoRecordMode`: пикер в
            // настройках держит не `Preferences`, а строку из defaults напрямую
            // (`@AppStorage`), и незнакомое ему значение оставило бы селектор
            // пустым — ни одного выбранного пункта из трёх.
            if raw == "off" || raw == "auto" {
                defaults.set(RecapProviderKind.ollama.rawValue, forKey: "recapProvider")
                return .ollama
            }
            return RecapProviderKind(rawValue: raw) ?? .ollama
        }
        set { defaults.set(newValue.rawValue, forKey: "recapProvider") }
    }

    var recapPrompt: String {
        get {
            let stored = defaults.string(forKey: "recapPrompt") ?? ""
            if stored.isEmpty { return RecapService.defaultPrompt }
            // Migrate previous built-in default so users pick up the new structure
            // without opening Settings → Reset. Custom prompts are left alone.
            if stored.hasPrefix("Ты готовишь краткий рекап рабочей встречи") {
                defaults.removeObject(forKey: "recapPrompt")
                return RecapService.defaultPrompt
            }
            return stored
        }
        set { defaults.set(newValue, forKey: "recapPrompt") }
    }

    /// Default recap model. Moved off `qwen2.5:7b` on 2026-07-27: a 4B reasoning
    /// model matches it on these transcripts at ~2/3 the disk and roughly half
    /// the weights, and the recap's remaining errors come from diarization / ASR
    /// / prompt, not model size.
    static let defaultRecapModel = "qwen3.5:4b"
    /// Superseded built-ins, migrated away on read (see below). `llama3.2` was
    /// the pre-1.10 default and was never bundled; its migration used to live in
    /// `AppState.bootstrap`, which missed any read that happened before launch
    /// finished — hence both are handled here now.
    private static let legacyRecapModels = ["qwen2.5:7b", "llama3.2"]

    /// True once the user asked for the local summary model (onboarding «Скачать»
    /// or Settings). Persisted so a download interrupted by quitting the app is
    /// resumed on the next launch instead of waiting for another manual trip to
    /// Settings — Ollama keeps partial blobs, so resuming is cheap.
    var localRecapModelRequested: Bool {
        get { defaults.bool(forKey: "localRecapModelRequested") }
        set { defaults.set(newValue, forKey: "localRecapModelRequested") }
    }

    var recapOllamaModel: String {
        get {
            let v = defaults.string(forKey: "recapOllamaModel") ?? ""
            if v.isEmpty { return Self.defaultRecapModel }
            // The settings pane's @AppStorage persists the value as soon as it
            // is opened, so 1.11 users have the old default written to disk and
            // would never pick up the new one. Deliberately narrow: only the
            // exact previous built-in migrates, a hand-picked model is kept.
            if Self.legacyRecapModels.contains(v) {
                defaults.removeObject(forKey: "recapOllamaModel")
                return Self.defaultRecapModel
            }
            return v
        }
        set { defaults.set(newValue, forKey: "recapOllamaModel") }
    }

    var recapOpenAIModel: String {
        get {
            let v = defaults.string(forKey: "recapOpenAIModel") ?? ""
            return v.isEmpty ? "gpt-4o-mini" : v
        }
        set { defaults.set(newValue, forKey: "recapOpenAIModel") }
    }

    var recapClaudeModel: String {
        get {
            let v = defaults.string(forKey: "recapClaudeModel") ?? ""
            return v.isEmpty ? "claude-sonnet-4-5" : v
        }
        set { defaults.set(newValue, forKey: "recapClaudeModel") }
    }

    var openAIAPIKey: String? {
        get { KeychainHelper.get(account: "openai_api_key") }
        set {
            if let newValue, !newValue.isEmpty {
                KeychainHelper.set(newValue, account: "openai_api_key")
            } else {
                KeychainHelper.delete(account: "openai_api_key")
            }
        }
    }

    var claudeAPIKey: String? {
        get { KeychainHelper.get(account: "claude_api_key") }
        set {
            if let newValue, !newValue.isEmpty {
                KeychainHelper.set(newValue, account: "claude_api_key")
            } else {
                KeychainHelper.delete(account: "claude_api_key")
            }
        }
    }

    // MARK: - Analytics (TelemetryDeck)

    /// Product signals for dogfood iteration. Default on; Settings can opt out.
    /// Never includes transcripts, paths, titles, or free text.
    var analyticsEnabled: Bool {
        get { defaults.object(forKey: "analyticsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "analyticsEnabled") }
    }

    // MARK: - Меню-бар

    /// Показывать ли иконку в строке меню.
    ///
    /// Выключенная иконка — единственное состояние, в котором у приложения не
    /// остаётся видимой ручки при закрытом окне: политика активации у него
    /// `.accessory`, значка в доке нет. Тупика при этом не возникает — повторный
    /// запуск из Spotlight поднимает окно (`applicationShouldHandleReopen`), —
    /// но именно поэтому выключатель живёт в настройках, где его можно вернуть,
    /// а из поповера доступно только выключение.
    var menuBarIconVisible: Bool {
        get { defaults.object(forKey: "menuBarIconVisible") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "menuBarIconVisible") }
    }

    // MARK: - Onboarding

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }

    /// The name the user gave — used to label the mic-dominant diarized speaker
    /// with their real name (see plan-v2 3.3).
    ///
    /// Empty means *not answered yet*, and that is load-bearing: it is what tells
    /// the rail it still owes the question (`SetupPromptMachine`). Nothing may
    /// pre-fill it with a guess; read `ownerName` instead.
    var userName: String {
        get { defaults.string(forKey: "userName") ?? "" }
        set { defaults.set(newValue, forKey: "userName") }
    }

    /// The name to actually label a speaker with.
    ///
    /// The macOS account name is a good enough guess and needs nobody's
    /// attention, so a transcript recorded before the rail got its answer is
    /// still signed rather than left with `Speaker 1`. It is a *fallback*, not an
    /// answer — see `userName`.
    var ownerName: String {
        let given = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return given.isEmpty ? NSFullUserName() : given
    }

    /// The rail asked about the calendar and the user pressed «Подключить».
    ///
    /// One-way, and separate from `calendarEnabled` on purpose: whether the
    /// calendar is *on* is a setting people turn off again, and reading the
    /// setting would bring the question back the first time somebody did.
    /// Whether they were *asked* happens once.
    var setupCalendarAsked: Bool {
        get { defaults.bool(forKey: "setupCalendarAsked") }
        set { defaults.set(newValue, forKey: "setupCalendarAsked") }
    }

    /// The rail asked about Claude and the user pressed «Подключить».
    ///
    /// Same shape as `setupCalendarAsked`, and for the same reason: the step is
    /// spent on the press, not on the outcome. Whether the connection then took
    /// is answered by the settings cell, which reads the config and the marker;
    /// bringing the rail's question back because it did not would turn a
    /// suggestion into nagging.
    var setupClaudeAsked: Bool {
        get { defaults.bool(forKey: "setupClaudeAsked") }
        set { defaults.set(newValue, forKey: "setupClaudeAsked") }
    }

    /// Read the system Calendar (EventKit) to name recordings. Off until the
    /// user opts in, since it triggers a calendar-access permission prompt.
    var calendarEnabled: Bool {
        get { defaults.bool(forKey: "calendarEnabled") }
        set { defaults.set(newValue, forKey: "calendarEnabled") }
    }

    // MARK: - Defaults

    static let basePath = NSHomeDirectory() + "/.meeting-recorder"
    private var defaultMeetingsPath: String { Self.basePath + "/meetings" }
    private var defaultRecordingsPath: String { Self.basePath + "/recordings" }
    static var peoplePath: String { basePath + "/people" }

    // Legacy path for migration
    static var legacyVoicesPath: String { basePath + "/voices" }
}
