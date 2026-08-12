import Foundation

/// A conferencing app Propeller can notice a call in.
///
/// Everything platform-specific is data, not code: adding one is a row in
/// `MeetingPlatform.all`, and the rules that read it are pure functions with
/// tests. The window-title rules matter most — Zoom's idle panels («Настройки»,
/// «Чат») used to false-trigger auto-record, and every fix there is one word in
/// a list away from starting a recording nobody asked for.
public struct MeetingPlatform: Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// Bundle identifiers of the desktop app, lowercased.
    public let bundleIDs: [String]
    /// Owner names as they appear in the window list, lowercased.
    public let windowOwners: [String]
    /// Helper processes spawned only for an active call. The cheapest signal —
    /// no window list, no permissions.
    public let callHelperProcesses: [String]
    /// Title fragments that mean a call is up (lowercased, matched as substrings).
    public let meetingTitleMarkers: [String]
    /// Titles of idle windows — never a call, whatever else matches.
    public let idleTitles: Set<String>
    /// Web address of the service, for calls held in a browser tab.
    public let webHostFragments: [String]
    /// Does a `PreventUserIdleDisplaySleep` assertion from this app mean a call?
    /// Only for apps measured to hold it for the call itself — an app that also
    /// holds it while sharing a screen answers `false`, because then the signal
    /// says "the display must stay awake", not "a call is on".
    public let sleepAssertionMeansCall: Bool
    /// Fragments of the assertion's own *name* that mean a call (lowercased,
    /// matched as substrings). Apps name their assertions, and the name is the
    /// difference between "a call is on" and "this app is busy" — VK writes
    /// «VK video call in progress» and holds nothing else. Empty means any
    /// display-sleep assertion from the app counts, which is how Zoom has
    /// shipped since phase 6.
    public let sleepAssertionNameMarkers: [String]

    public init(
        id: String,
        displayName: String,
        bundleIDs: [String],
        windowOwners: [String],
        callHelperProcesses: [String],
        meetingTitleMarkers: [String],
        idleTitles: Set<String>,
        webHostFragments: [String] = [],
        sleepAssertionMeansCall: Bool = false,
        sleepAssertionNameMarkers: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.windowOwners = windowOwners
        self.callHelperProcesses = callHelperProcesses
        self.meetingTitleMarkers = meetingTitleMarkers
        self.idleTitles = idleTitles
        self.webHostFragments = webHostFragments
        self.sleepAssertionMeansCall = sleepAssertionMeansCall
        self.sleepAssertionNameMarkers = sleepAssertionNameMarkers
    }
}

extension MeetingPlatform {

    public static let zoom = MeetingPlatform(
        id: "zoom",
        displayName: "Zoom",
        bundleIDs: ["us.zoom.xos"],
        windowOwners: ["zoom.us"],
        // Spawned when a call starts; `caphost` alone is idle-safe and ignored —
        // it sits running from launch. Confirmed on a live call 2026-07-29:
        // `CptHost` appeared at the exact second the meeting was joined, while
        // `caphost` had been up for four hours. `aomhost` stays because older
        // Zoom builds spawned it and the extra comparison costs nothing.
        callHelperProcesses: ["cpthost", "aomhost"],
        meetingTitleMarkers: [
            "zoom meeting", "webinar", "meeting id", "конференция", "вебинар",
        ],
        idleTitles: [
            "", "zoom", "zoom.us", "zoom workplace", "zoom - free account",
            "login", "sign in", "settings", "preferences", "chat", "contacts",
            "войти", "вход", "настройки", "параметры", "чат", "контакты", "зум",
        ],
        // Zoom holds the assertion for the call — it is the fallback behind
        // `CptHost`, and it shipped that way since phase 6.
        sleepAssertionMeansCall: true
    )

    /// Контур.Толк.
    ///
    /// **Unverified against a live install** — nobody on the team had it when
    /// this was written, so the identifiers below are the plausible ones and
    /// must be confirmed with `Diagnostics.describeRunningApps()` before
    /// release. The rules are data precisely so that confirming them is a one
    /// line edit, not a code change.
    ///
    /// Talk is commonly used *in a browser*, so `webHostFragments` carries the
    /// address: a browser window whose title mentions the service counts as the
    /// same platform.
    public static let konturTalk = MeetingPlatform(
        id: "kontur-talk",
        displayName: "Контур.Толк",
        // Подтверждено на живой установке 2026-07-30 (`lsappinfo list`):
        // "Толк" → kontur.talk, "Толк Helper" → kontur.talk.helper. Без "ru."
        // в начале — приложение не следует обратному DNS для своего домена.
        // Прежние три варианта ни разу не совпадали с реальностью.
        bundleIDs: ["kontur.talk", "kontur.talk.helper"],
        windowOwners: ["толк", "kontur talk", "контур.толк", "talk"],
        // Пусто НЕ потому, что не проверяли, а потому, что проверили и
        // нечего вписать. Живой звонок 2026-07-30: процессы — «Толк»,
        // два «Толк Helper», пять «Толк Helper (Renderer)» — обычная
        // Electron-архитектура (main + сетевой хелпер + рендереры на
        // каждое окно), и она поднимается **при любом запуске приложения**,
        // звонок идёт или нет. У Zoom `CptHost` — не такой: он существует
        // только внутри звонка, поэтому его можно класть сюда как
        // достаточное доказательство «звонок идёт». У Толка такого процесса
        // нет вовсе — вписать сюда обычный хелпер значило бы, что
        // `MeetingDetector` посчитает звонком сам факт открытого Толка и
        // включит запись, стоит человеку просто запустить приложение.
        //
        // Для прицела тапа (`TapTargetPolicy`) это не проблема — туда
        // процессы попадают по bundle id, который уже поймали правильно.
        // Проблема в другом: у Толка сейчас **нет вообще никакого сигнала**
        // «звонок идёт» — раньше им был заголовок окна, но разрешение на
        // запись экрана мы больше не спрашиваем. Активные TCP-соединения на
        // 443 у одного из хелперов замерены на живом звонке, но это не
        // отличить от простого открытого приложения без независимого способа
        // узнать, что порт именно сейчас несёт медиатрафик, а не сигналинг.
        callHelperProcesses: [],
        meetingTitleMarkers: [
            "конференция", "встреча", "созвон", "комната", "meeting", "call",
        ],
        idleTitles: [
            "", "толк", "контур.толк", "kontur talk", "talk",
            "настройки", "параметры", "чат", "контакты", "календарь",
            "settings", "preferences", "chat", "contacts", "calendar",
            "вход", "войти", "login", "sign in",
        ],
        webHostFragments: ["talk.kontur.ru", "контур.толк"],
        // Толк держит `PreventUserIdleDisplaySleep`, пока кто-нибудь на звонке
        // демонстрирует экран, — Chromium внутри Electron берёт display wake
        // lock на всё время захвата экрана. Для звонка как такового ассерта
        // нет. На 1.15 это значило, что автозапись включалась на старте шера и
        // выключалась на его остановке: тестер получал запись куска чужой
        // демонстрации вместо встречи и обрыв записи посреди разговора.
        // Поэтому у Толка автодетекта нет — встречу в нём начинают руками.
        sleepAssertionMeansCall: false
    )

    /// VK Звонки.
    ///
    /// Снято с живого звонка 2026-08-11 (звонок шёл, камера и микрофон
    /// выключены — то есть это не «видео», это звонок):
    ///
    /// - `lsappinfo list`: «VK Звонки» → `com.vk.calls.native.1`, исполняемый
    ///   файл `VK Calls`. Bundle id кончается цифрой — из-за этого пришлось
    ///   чинить `ownsProcess`, см. там.
    /// - процессов звонка нет вовсе: `VK Calls` и `crashpad_handler` подняты с
    ///   запуска приложения и живут ровно столько же. Zoom-подобного `CptHost`,
    ///   который существует только внутри звонка, у VK не бывает.
    /// - `pmset -g assertions`: `NoDisplaySleepAssertion named: "VK video call
    ///   in progress"`, взят через 37 с после запуска приложения — то есть на
    ///   старте звонка, а не при открытии окна. **Пропал за один тик (3 с)
    ///   после завершения звонка**, приложение при этом осталось открытым и
    ///   больше тридцати секунд не держало ничего.
    ///
    /// Заголовков окон здесь нет и списки пустые — не потому, что не проверяли,
    /// а потому, что без «Записи экрана» `CGWindowListCopyWindowInfo` отдаёт
    /// пустые имена, и ни один заголовок VK не видел никто. Вписать сюда
    /// правдоподобные слова значило бы держать в таблице непроверенное правило,
    /// которое включает запись.
    public static let vkCalls = MeetingPlatform(
        id: "vk-calls",
        displayName: "VK Звонки",
        bundleIDs: ["com.vk.calls.native.1"],
        // Обе формы имени настоящие: LaunchServices зовёт приложение «VK
        // Звонки», исполняемый файл — `VK Calls`, и ассерт держит именно он.
        windowOwners: ["vk звонки", "vk calls"],
        callHelperProcesses: [],
        meetingTitleMarkers: [],
        idleTitles: [],
        // Единственный сигнал — ассерт, и он сужен до своего имени. Урок Толка
        // был не «ассерт врёт», а «ассерт значит "экрану нельзя гаснуть"»; имя
        // отвечает на другой вопрос, и у VK отвечает прямым текстом.
        sleepAssertionMeansCall: true,
        sleepAssertionNameMarkers: ["video call in progress"]
    )

    public static let all: [MeetingPlatform] = [.zoom, .konturTalk, .vkCalls]

    public static func platform(id: String) -> MeetingPlatform? {
        all.first { $0.id == id }
    }

    /// Чей display-sleep ассерт считается идущим звонком.
    ///
    /// - Parameters:
    ///   - live: платформы, чьи приложения запущены сейчас.
    ///   - holdingAssertion: id тех из них, кто прямо сейчас держит ассерт,
    ///     прошедший проверку имени (`assertionNameMeansCall`).
    ///
    /// Раньше на этот вопрос отвечала строчка `live.count == 1` в детекторе:
    /// открыто два конференц-приложения — сигнал ассерта не работает ни для
    /// кого. Замерено 2026-08-11: у человека постоянно открыт простаивающий
    /// Zoom, и живой звонок VK не был опознан ни разу за 76 секунд, хотя ассерт
    /// держался всё это время. Считать надо не приложения, а **держателей**:
    /// простаивающий Zoom не держит ничего (проверено тем же днём).
    ///
    /// Двое держателей — по-прежнему ничей звонок. Не потому, что так
    /// безопаснее вообще, а потому, что запись одна: выбрать из двоих значит
    /// угадать, в какой встрече человек, а угадывать здесь нечем.
    public static func callFromAssertion(
        live: [MeetingPlatform],
        holdingAssertion ids: [String]
    ) -> String? {
        let holders = live.filter { $0.sleepAssertionMeansCall && ids.contains($0.id) }
        return holders.count == 1 ? holders[0].id : nil
    }

    /// Запущенное приложение, каким его видит `NSWorkspace`.
    public struct RunningApp: Equatable, Sendable {
        public let pid: Int32
        public let bundleID: String?
        public let name: String?

        public init(pid: Int32 = 0, bundleID: String? = nil, name: String? = nil) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// Платформы, чьи приложения сейчас запущены.
    ///
    /// - Parameter excludingPID: процесс, о завершении которого только что
    ///   пришло уведомление. `NSWorkspace.runningApplications` какое-то время
    ///   ещё отдаёт покойника, и без этого «остался ли кто-нибудь ещё» отвечает
    ///   «да» про него самого.
    ///
    /// Ответ на этот вопрос решает, гасить ли опрос: гасить можно, только когда
    /// не осталось **ни одного** конференц-приложения. Замерено 12.08.2026: VK
    /// Звонки закрылись в 11:16:51 при запущенном с 10 августа Zoom, детектор
    /// снял таймер на любом завершении — и автозапись молчала до перезапуска
    /// приложения, потому что таймер поднимает только событие *запуска*, а Zoom
    /// уже был запущен. Zoom-звонок в 14:00 не был опознан вовсе.
    public static func live(in apps: [RunningApp], excludingPID: Int32? = nil) -> [MeetingPlatform] {
        all.filter { platform in
            apps.contains { app in
                guard app.pid != excludingPID else { return false }
                return platform.owns(bundleID: app.bundleID, appName: app.name)
            }
        }
    }
}

// MARK: - Rules

extension MeetingPlatform {

    public func owns(bundleID: String?, appName: String?) -> Bool {
        if let bundleID, bundleIDs.contains(bundleID.lowercased()) { return true }
        if let appName {
            let name = appName.lowercased()
            if windowOwners.contains(name) { return true }
        }
        return false
    }

    /// Does a process with this executable name belong to this platform?
    ///
    /// Substring match, because helpers are named after the app they serve
    /// («Толк Helper (Renderer)», `zoom.us`). Used to attribute a power
    /// assertion to the app holding it.
    public func ownsProcess(named rawName: String) -> Bool {
        let name = rawName.lowercased()
        if windowOwners.contains(where: { name.contains($0) }) { return true }
        return bundleIDs.contains { id in
            guard let last = id.split(separator: ".").last else { return false }
            // Последний компонент годится в имя процесса, только если он сам
            // по себе что-то значит. У VK bundle id — `com.vk.calls.native.1`,
            // и без этой проверки платформе принадлежал бы **любой** процесс с
            // единицей в имени: `python3.11`, державший display-sleep, начал бы
            // звонок VK. Три символа и не одни цифры — граница, за которой
            // совпадение перестаёт быть случайным.
            guard last.count >= 3, last.contains(where: { !$0.isNumber }) else { return false }
            return name.contains(last)
        }
    }

    /// Значит ли имя ассерта, что идёт звонок?
    ///
    /// Пустой список маркеров — «любой display-sleep ассерт этого приложения
    /// считается», как у Zoom с шестой фазы. Непустой — сигналом остаётся ровно
    /// то, что замерено на живом звонке, и «приложение держит экран не спящим»
    /// само по себе больше ничего не значит.
    public func assertionNameMeansCall(_ rawName: String?) -> Bool {
        guard !sleepAssertionNameMarkers.isEmpty else { return true }
        guard let rawName else { return false }
        let name = rawName.lowercased()
        return sleepAssertionNameMarkers.contains { name.contains($0) }
    }

    /// Does this window title mean a call is up?
    ///
    /// Idle titles win over markers: a settings panel called «Настройки» must
    /// never start a recording, even when the app is a conferencing one.
    public func titleMeansCall(_ rawTitle: String) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty, !idleTitles.contains(title) else { return false }
        return meetingTitleMarkers.contains { title.contains($0) }
    }

    /// A browser window can be the call itself when the service runs on the web.
    /// Requires both the address and a call marker, so the service's landing
    /// page or a docs tab does not trigger anything.
    public func browserTitleMeansCall(_ rawTitle: String) -> Bool {
        guard !webHostFragments.isEmpty else { return false }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty, !idleTitles.contains(title) else { return false }
        guard webHostFragments.contains(where: { title.contains($0) }) else { return false }
        return meetingTitleMarkers.contains { title.contains($0) }
    }
}

/// What one poll saw.
public struct MeetingSnapshot: Equatable, Sendable {
    /// Platform whose call is up, if any.
    public let platformID: String?
    public let appRunning: Bool
    public let signals: [String]

    public var inMeeting: Bool { platformID != nil }

    public init(platformID: String?, appRunning: Bool, signals: [String]) {
        self.platformID = platformID
        self.appRunning = appRunning
        self.signals = signals
    }

    public static let idle = MeetingSnapshot(platformID: nil, appRunning: false, signals: [])
}

/// Turns raw poll readings into "are we in a call", with hysteresis.
///
/// Kept apart from the polling so the debounce can be tested: a detector that
/// flaps starts and stops recordings on its own, and that is not something to
/// discover during a real meeting.
public struct MeetingDebounce {
    /// Consecutive positives before a call counts as started.
    public let enterThreshold: Int
    /// Consecutive negatives before it is considered over. Higher than
    /// `enterThreshold`: a brief blind spot mid-call must not stop a recording.
    public let exitThreshold: Int

    private var positives = 0
    private var negatives = 0
    public private(set) var isInMeeting = false

    public init(enterThreshold: Int = 2, exitThreshold: Int = 3) {
        self.enterThreshold = enterThreshold
        self.exitThreshold = exitThreshold
    }

    public enum Transition: Equatable, Sendable {
        case none
        case started(platformID: String)
        case ended
    }

    public mutating func observe(_ snapshot: MeetingSnapshot) -> Transition {
        if let platformID = snapshot.platformID {
            positives += 1
            negatives = 0
            if !isInMeeting, positives >= enterThreshold {
                isInMeeting = true
                return .started(platformID: platformID)
            }
        } else {
            negatives += 1
            positives = 0
            if isInMeeting, negatives >= exitThreshold {
                isInMeeting = false
                return .ended
            }
        }
        return .none
    }

    /// The app quit — end immediately, no debounce to wait for.
    public mutating func reset() -> Transition {
        positives = 0
        negatives = 0
        guard isInMeeting else { return .none }
        isInMeeting = false
        return .ended
    }
}
