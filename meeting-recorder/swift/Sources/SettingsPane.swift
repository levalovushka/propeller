import SwiftUI
import PropellerUI
import PropellerPure
import ServiceManagement

/// Настройки, как их видит человек, — состояние правой панели.
///
/// Экран перебран 2026-08-20 по прототипу `design/prototypes/settings-v2.html`.
/// Что изменилось против версии от 07 августа и почему:
///
/// - **Жанры разведены.** «Доступ» стоит первым и держит то, что решает не
///   человек, а система: разрешения и то, что из них следует. Ниже — только
///   решения человека. До этого разрешение macOS, тумблер телеметрии и выбор
///   модели стояли вперемешку, хотя отвечают на разные вопросы.
/// - **Заголовок строки называет выгоду, а не механизм.** «Доступ к
///   приложениям» — это имя разрешения в System Settings; человек приходит с
///   «почему не видно, кто говорил». Стало «Имена спикеров из Zoom».
/// - **Аналитика уехала в «О программе»** (решение владельца): она про само
///   приложение, а не про архив. Группы «Приватность» больше нет — в ней
///   оставалось два тумблера про разное.
/// - **Вторая строка получила род.** Пояснение, значение, процесс, отказ
///   переживаемый и отказ системы — пять смыслов, до этого один цвет
///   (`SettingsSubtitleTone`). «Не запущен» больше не читается как справка.
/// - **Акцент инвертирован.** Синяя кнопка — на несделанном, галочка «сделано»
///   тихая. Раньше подсвечено было ровно то, что трогать не надо.
/// - **Путь не набирают руками.** Папка — это имя, путь и кнопка «Изменить…»;
///   текстовое поле пути было поверхностью опечатки, а не выбором.
/// - **Промпт в поле 80 pt** вместо 260: за ним сразу начинается «Хранилище».
///   Подэкранов у промпта и словаря нет (решение владельца) — чем их заменить,
///   открытая вилка в прототипе.
///
/// Имена групп «MCP» и «Хранилище» владелец оставил как были: правило «вопрос, а
/// не механизм» действует на строках, но не на этих двух заголовках.
///
/// Вёрстка — `PropellerUI/SettingsKit.swift`. Здесь только то, что читает и
/// пишет `Preferences`, `AppState` и Keychain.
struct SettingsPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsColumn {
            AccessSettingsGroup(state: state)
            RecordingSettingsGroup(state: state)
            ModelsSettingsGroup(state: state)
            StorageSettingsGroup(state: state)
            ClaudeSettingsGroup(state: state)
            AboutSettingsGroup()
        }
    }
}

// MARK: - Доступ

/// Что решает не человек, а система: два разрешения macOS.
///
/// Группа стоит первой, потому что от неё зависит, работает ли то, что ниже:
/// без доступа к приложениям в расшифровке не будет имён, без календаря —
/// названий. Обе строки — не настройки в смысле §3 дока, а состояние мира, и
/// живут отдельно ровно поэтому.
private struct AccessSettingsGroup: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsGroup("Доступ") {
            SpeakerAccessRow()
            CalendarAccessRow(state: state)
        }
    }
}

/// Доступ к приложениям — то, чем читаются имена спикеров из окна Zoom.
///
/// Заголовок называет то, что человек получит, а не имя разрешения: имя
/// разрешения он увидит в System Settings, куда его и уводит кнопка.
///
/// Polled, not cached: the grant lands in System Settings, sometimes only after
/// a relaunch, and the tick must appear the moment it is true — same contract as
/// the onboarding plate's rows.
private struct SpeakerAccessRow: View {
    @State private var granted = AXIsProcessTrusted()
    @State private var promptShown = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsCell(
            "Имена спикеров из\u{00A0}Zoom",
            // Разрешено — сказать нечего: об этом говорит галочка. Не разрешено —
            // сказать надо, потому что цена молчания видна только в расшифровке.
            subtitle: granted ? nil : "Без доступа — «Участник\u{00A0}1» и «Участник\u{00A0}2»"
        ) {
            if granted {
                SettingsCheck()
            } else {
                SettingsButton("Разрешить", prominent: true) { press() }
            }
        }
        .onReceive(poll) { _ in granted = AXIsProcessTrusted() }
    }

    private func press() {
        // Системное окно показывается один раз за установку. Второй нажим уже
        // ничего не спросит, поэтому ведёт туда, где решение принимают руками.
        if promptShown {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        promptShown = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Строка календаря: единственное место, где приложение признаётся, что
/// названий из календаря не будет.
///
/// Решение состояния — в `PropellerPure/CalendarAccess.swift`; здесь только
/// чтение системы и нажатие. Тексты состояний живут там и покрыты тестами —
/// поэтому переписан только заголовок строки. Перечитывает ответ системы на
/// открытии настроек и на возврате в приложение — тот же приём, что у
/// `MCPClientRow`: человек уходит выдавать доступ руками и обязан вернуться к
/// изменившейся строке.
private struct CalendarAccessRow: View {
    @ObservedObject var state: AppState
    @ObservedObject private var calendar = CalendarService.shared
    @AppStorage("calendarEnabled") private var calendarEnabled = false

    private var row: CalendarSettingsRow {
        .state(enabled: calendarEnabled, access: calendar.access)
    }

    var body: some View {
        SettingsCell("Названия встреч из\u{00A0}Календаря", subtitle: row.subtitle) {
            control
        }
        .onAppear { calendar.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in calendar.refreshAccess() }
    }

    @ViewBuilder
    private var control: some View {
        if let title = row.actionTitle {
            SettingsButton(title, prominent: true) { press() }
        } else if row.showsCheckmark {
            SettingsCheck()
        } else {
            EmptyView()
        }
    }

    private func press() {
        // После отказа системы просить снова нечего: окна не будет, и кнопка
        // «Попробовать снова» читалась бы как сломанное приложение. Единственный
        // работающий путь — System Settings.
        if row.opensSystemSettings {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            ) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        state.enableCalendarFromSettings()
    }
}

// MARK: - Запись

/// Когда приложение оживает само и чем себя показывает.
///
/// Заголовки — существительными, все пять: глаз идёт по группе одним ритмом, а
/// не спотыкается на «Показывать…» посреди «Автоматической записи». «Запуск
/// Propeller при входе» назван с субъектом намеренно: без него строка в группе
/// «Запись» читалась как «запускать запись при входе».
private struct RecordingSettingsGroup: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginError: String?
    @AppStorage("autoRecordMode") private var autoRecordMode = AutoRecordMode.auto.rawValue
    @AppStorage("menuBarIconVisible") private var menuBarIconVisible = true
    @AppStorage("notchIndicator") private var notchIndicator = true
    @AppStorage("userName") private var userName = ""

    var body: some View {
        SettingsGroup("Запись") {
            // Zoom назван поимённо: у Толка сигнала «идёт звонок» нет вовсе, и
            // обещать здесь «звонок» вообще значило бы обещать старт, который
            // не наступит.
            SettingsCell(
                "Автоматическая запись",
                subtitle: "Вместе со звонком в\u{00A0}Zoom"
            ) {
                SettingsSwitch(isOn: autoRecord)
            }
            .onChange(of: autoRecordMode) { _, val in
                Preferences.shared.autoRecordMode = AutoRecordMode(rawValue: val) ?? .auto
                state.applyAutoRecordMode()
            }

            SettingsCell(
                "Запуск Propeller при\u{00A0}входе",
                // Единственная строка, которая здесь появляется: отказ системы.
                // Она не описывает настройку, она отвечает на нажатие — и потому
                // красится как отказ, а не как подсказка.
                subtitle: launchAtLoginError,
                tone: .failure
            ) {
                SettingsSwitch(isOn: $launchAtLogin)
            }
            .onChange(of: launchAtLogin) { _, want in
                do {
                    try LoginItem.setEnabled(want)
                    launchAtLoginError = nil
                } catch {
                    // Вернуть переключатель к правде и назвать причину.
                    launchAtLogin = LoginItem.isEnabled
                    launchAtLoginError = error.localizedDescription
                }
            }

            // Выключатель живёт здесь, потому что вернуть иконку можно только
            // отсюда: в поповере, которого без неё не будет, доступно лишь
            // «Скрыть». Сцена читает тот же ключ (`MenuBarExtra(isInserted:)`).
            SettingsCell("Иконка в\u{00A0}меню баре") {
                SettingsSwitch(isOn: $menuBarIconVisible)
            }

            // Единственная поверхность, которую приложение рисует поверх чужих
            // окон, — единственная, у которой есть выключатель. Подпись меняется
            // вместе с железом: на маке без выреза выключать нечего, и честнее
            // сказать это, чем прятать строку и оставить человека гадать, куда
            // делась настройка, про которую он читал.
            SettingsCell(
                "Индикация записи в\u{00A0}чёлке",
                subtitle: NotchController.hardwareHasNotch
                    ? "Заметка по\u{00A0}⌃⌥N"
                    : "На этом маке нет выреза — заметки живут в\u{00A0}окне встречи"
            ) {
                SettingsSwitch(isOn: $notchIndicator)
                    .disabled(!NotchController.hardwareHasNotch)
            }
            .onChange(of: notchIndicator) { _, _ in
                NotchController.shared.preferenceChanged()
            }

            // Плейсхолдер — то самое системное имя, которым подпишет фолбэк
            // (`Preferences.ownerName`). Пустое поле поэтому не врёт: оно
            // показывает, как встреча будет подписана, если ничего не вводить.
            // Поле узкое: имя человека короче любого пути, а широкое поле
            // обещало бы, что сюда пишут больше, чем два слова.
            SettingsCell("Ваше имя") {
                SettingsField(
                    NSFullUserName(),
                    text: $userName,
                    width: Tokens.Settings.fieldNarrowWidth
                )
            }
            .onChange(of: userName) { _, val in
                state.setOwnerNameFromSettings(val)
            }
        }
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            // Через `Preferences`, а не из defaults напрямую: там живёт миграция
            // удалённого «Спросить», и без этого чтения выключатель показал бы
            // «выкл» при записанном `ask`.
            autoRecordMode = Preferences.shared.autoRecordMode.rawValue
        }
    }

    /// Два режима — выключатель, а не пикер из двух пунктов. `AutoRecordMode`
    /// остаётся на диске строкой: её `rawValue` уже лежат у людей.
    private var autoRecord: Binding<Bool> {
        Binding(
            get: { (AutoRecordMode(rawValue: autoRecordMode) ?? .auto) == .auto },
            set: { autoRecordMode = ($0 ? AutoRecordMode.auto : .off).rawValue }
        )
    }
}

// MARK: - Расшифровка и саммари

/// Во что превращается записанный звук — сначала в текст, потом в конспект.
///
/// Группа называется тем, что делает, а не механизмом, которым делает: «Нейросети»
/// отвечали на вопрос, которого человек не задавал.
private struct ModelsSettingsGroup: View {
    @ObservedObject var state: AppState
    @AppStorage("domainTerms") private var domainTerms = ""
    @AppStorage("recapProvider") private var recapProvider = RecapProviderKind.ollama.rawValue
    @AppStorage("recapOpenAIModel") private var recapOpenAIModel = "gpt-4o-mini"
    @AppStorage("recapClaudeModel") private var recapClaudeModel = "claude-sonnet-4-5"
    @AppStorage("recapOpenRouterModel") private var recapOpenRouterModel = "anthropic/claude-sonnet-4.5"
    @State private var recapPrompt: String = Preferences.shared.recapPrompt
    // Пустые, а заполняются в `onAppear`. Инициализатор свойства выполняется на
    // *каждой* пересборке структуры, даже когда `@State` его результат уже
    // игнорирует, — а это поход в Keychain, и на открытых настройках во время
    // записи он случался бы каждую секунду вместе с тиком таймера.
    @State private var openAIKey: String = ""
    @State private var claudeKey: String = ""
    @State private var openRouterKey: String = ""
    @State private var ollamaReachable: Bool? = nil
    @State private var restartStatus: String?
    @State private var pendingRestart: DispatchWorkItem?

    var body: some View {
        SettingsGroup("Расшифровка и саммари") {
            // Движка расшифровки здесь нет: он ровно один, выбрать другой
            // нельзя, а строка без выбора — не настройка.
            //
            // Заголовок — вопрос человека («кто пишет саммари»), а не имя поля.
            // Состояние движка — второй строкой у самого выбора: вопрос «кто
            // пишет саммари» и вопрос «отвечает ли он» — один вопрос.
            SettingsCell(
                "Кто пишет саммари",
                subtitle: providerStatus.text,
                tone: providerStatus.tone
            ) {
                Picker("", selection: $recapProvider) {
                    ForEach(RecapProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .onChange(of: recapProvider) { _, val in
                Preferences.shared.recapProvider = RecapProviderKind(rawValue: val) ?? .ollama
                // Meetings that were waiting on a summary can go now — and
                // ones that gave up waiting are un-parked.
                state.summaryProviderChanged()
            }

            // Настройки — только у выбранного провайдера. Ключ OpenAI рядом с
            // выбранной Ollama ничего не настраивает: он настраивает то, чем
            // приложение сейчас не пользуется.
            //
            // У Ollama не показывается ничего: имя модели приложение выбирает
            // само и само же её привозит (`AppState.ensureSummaryModel`,
            // `Preferences.recapOllamaModel` с миграцией старых дефолтов). Всё,
            // что человеку тут правда нужно знать, — едет модель или уже
            // отвечает, — стоит второй строкой у выбора.
            if provider == .openai {
                keyRow("Ключ OpenAI", placeholder: "sk-…", text: $openAIKey) { val in
                    Preferences.shared.openAIAPIKey = val
                }
                modelRow("Модель OpenAI", placeholder: "gpt-4o-mini", text: $recapOpenAIModel) { val in
                    Preferences.shared.recapOpenAIModel = val
                }
            }
            if provider == .claude {
                keyRow("Ключ Claude", placeholder: "sk-ant-…", text: $claudeKey) { val in
                    Preferences.shared.claudeAPIKey = val
                }
                modelRow("Модель Claude", placeholder: "claude-sonnet-4-5", text: $recapClaudeModel) { val in
                    Preferences.shared.recapClaudeModel = val
                }
            }
            // OpenRouter — та же пара строк, что у остальных облачных, и
            // намеренно без списка моделей: их там тысячи, они меняются каждую
            // неделю, и любой встроенный список устареет к следующему релизу.
            // Кто пришёл за OpenRouter, знает имя модели и приносит его с
            // собой; подсказка формата стоит в подписи — и только здесь, потому
            // что префикс вендора и есть единственное, чем это поле отличается
            // от соседних.
            if provider == .openrouter {
                keyRow("Ключ OpenRouter", placeholder: "sk-or-…", text: $openRouterKey) { val in
                    Preferences.shared.openRouterAPIKey = val
                }
                modelRow(
                    "Модель OpenRouter",
                    placeholder: "anthropic/claude-sonnet-4.5",
                    subtitle: "С префиксом вендора, как в каталоге OpenRouter",
                    text: $recapOpenRouterModel
                ) { val in
                    Preferences.shared.recapOpenRouterModel = val
                }
            }

            // Словарь стоит перед промптом: он про распознавание, то есть про
            // шаг раньше. Подпись называет, что сюда пишут, — не то, что с этим
            // потом случится: «ломает распознаватель» человек и так знает, он
            // потому и пришёл.
            SettingsStack("Личный словарь", subtitle: "Имена, компании и сленг") {
                VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                    SettingsField("напр. Газпромнефть, Аэрофлот", text: $domainTerms)
                    if let restartStatus {
                        Text(restartStatus)
                            .typo(Tokens.Settings.Typo.subtitle)
                            .foregroundStyle(Tokens.Settings.subtitleProgress)
                    }
                }
            }
            .onChange(of: domainTerms) { _, val in
                Preferences.shared.domainTerms = val
                scheduleRestart()
            }

            // «Сбросить промпт» здесь больше нет, и замены ей не нужно: пустое
            // поле **и есть** сброс — `Preferences.recapPrompt` отдаёт дефолт,
            // когда сохранённого нет. Об этом и говорит подпись; вторая её
            // половина — про прошлое, как требует §6.2 дока.
            SettingsStack(
                "Промпт",
                subtitle: "Пусто — встроенный; старые саммари не меняются"
            ) {
                SettingsEditor(text: $recapPrompt)
            }
            .onChange(of: recapPrompt) { _, val in
                Preferences.shared.recapPrompt = val
            }
        }
        // Модель доехала — строка состояния обязана это заметить сама: кнопки,
        // которой её можно было переспросить, больше нет.
        .onChange(of: state.ollamaSetupMessage) { _, msg in
            if msg == "Модель готова" {
                ollamaReachable = true
                state.refreshLocalRecapModelState()
            }
        }
        .onAppear {
            state.refreshLocalRecapModelState()
            // То же, что у автозаписи: миграция «Выкл» и «Авто» живёт в
            // `Preferences`, и пикер обязан читать провайдера через неё.
            recapProvider = Preferences.shared.recapProvider.rawValue
            recapPrompt = Preferences.shared.recapPrompt
            openAIKey = Preferences.shared.openAIAPIKey ?? ""
            claudeKey = Preferences.shared.claudeAPIKey ?? ""
            openRouterKey = Preferences.shared.openRouterAPIKey ?? ""
            recapOpenAIModel = Preferences.shared.recapOpenAIModel
            recapClaudeModel = Preferences.shared.recapClaudeModel
            recapOpenRouterModel = Preferences.shared.recapOpenRouterModel
            Task { ollamaReachable = await RecapService.shared.probeOllama() }
        }
    }

    // MARK: Провайдеры

    private var provider: RecapProviderKind {
        RecapProviderKind(rawValue: recapProvider) ?? .ollama
    }

    /// Ключ облачного провайдера. Пишется в Keychain и будит пайплайн: встреча,
    /// которая ждала саммари, может пойти сразу, как ключ появился.
    private func keyRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        SettingsStack(title, subtitle: "Хранится в Keychain") {
            SettingsField(placeholder, text: text, secure: true)
        }
        .onChange(of: text.wrappedValue) { _, val in
            onCommit(val)
            state.summaryProviderChanged()
        }
    }

    private func modelRow(
        _ title: String,
        placeholder: String,
        subtitle: String? = nil,
        text: Binding<String>,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        SettingsStack(title, subtitle: subtitle) {
            SettingsField(placeholder, text: text)
        }
        .onChange(of: text.wrappedValue) { _, val in onCommit(val) }
    }

    /// Что сказать про выбранного провайдера и каким родом второй строки.
    ///
    /// Про локальный: едет, отвечает или не поднялся — и «не поднялся» это
    /// предупреждение, а не пояснение. Слова «транскрипт не уходит с мака» тут
    /// нет намеренно: «локально» ровно это и означает.
    ///
    /// Про облачный сказать есть что одно, и это не про качество: куда уедет
    /// транскрипт. Это же и есть цена выбора.
    private var providerStatus: (text: String?, tone: SettingsSubtitleTone) {
        switch provider {
        case .openai:     return ("Транскрипт уходит в OpenAI", .help)
        case .claude:     return ("Транскрипт уходит в Anthropic", .help)
        case .openrouter: return ("Транскрипт уходит в OpenRouter, дальше — вендору модели", .help)
        case .ollama:
            // Пока модель едет — процент. Полосы загрузки под этой строкой
            // больше нет, и это единственное место, где про загрузку сказано.
            if let frac = state.ollamaSetupProgress {
                return ("Скачиваем модель… \(Int(frac * 100))%", .progress)
            }
            switch ollamaReachable {
            case true: return ("Отвечает локально", .help)
            case false: return ("Не запущен", .warning)
            case nil: return ("Проверяем…", .progress)
            }
        }
    }

    /// Hotwords are a server-launch argument for gigastt, not per-request, so
    /// picking up an edited term list means restarting the sidecar. Debounced
    /// so a whole typed phrase triggers one restart, not one per keystroke.
    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem {
            restartStatus = "Перезапуск распознавателя…"
            Task {
                do {
                    try await GigasttSidecar.shared.restart()
                    await MainActor.run { restartStatus = nil }
                } catch {
                    await MainActor.run {
                        restartStatus = "Распознаватель не перезапустился: \(error.localizedDescription)"
                    }
                }
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - MCP

/// Группа «MCP»: по строке на клиента, у каждой одна кнопка и ни одного диалога.
///
/// Имя группы владелец оставил протоколом, а не вопросом («кто ещё читает
/// архив»): кто пришёл сюда подключать клиента, ищет именно эти три буквы.
///
/// Чужой конфиг можно отредактировать руками — сегодня это единственный способ,
/// и он не работает: путь надо знать. Здесь всё, что от человека требуется, —
/// нажать; остальное (найти приложение, сделать копию его конфига, дописать в
/// него запись) делает `MCPConnector`.
///
/// **Состояние выводится при каждом открытии, а не хранится.** Файлы чужие: их
/// может переписать сам клиент, и сохранённое «подключено» разошлось бы с
/// правдой молча. Плюс перечитывание на возврате в приложение — человек уходит
/// перезапускать Клода при открытых настройках и возвращается к строке, которая
/// обязана уже поменяться.
///
/// Кнопки «Перезапустить» здесь нет намеренно: закрывать чужое приложение с
/// открытыми разговорами — не наше дело.
///
/// Не `private` только ради галереи: её кадры рисуют эту же группу, а не её
/// копию, — иначе справочник показывал бы то, чего в приложении нет.
struct ClaudeSettingsGroup: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsGroup("MCP") {
            ForEach(MCPClient.allCases, id: \.self) { client in
                if client.configLocation == nil {
                    // Клиент без конфига — значит и без кнопки: его подключают
                    // командой, и всё, что мы можем, — дать её скопировать.
                    MCPCommandRow(client: client)
                } else {
                    MCPClientRow(state: state, client: client)
                }
            }
        }
    }
}

/// Строка клиента, которого подключают руками.
///
/// Состояния у неё нет и быть не может: в чужой конфиг мы не смотрим, а
/// `claude mcp add` кладёт запись туда, куда сам решит — в проект, в профиль
/// или в сессию. Единственная честная роль строки здесь — отдать команду.
private struct MCPCommandRow: View {
    let client: MCPClient

    var body: some View {
        SettingsCell(client.rowTitle, subtitle: nil) {
            if let command = MCPConnector.claudeCodeCommand {
                SettingsCommand(command) { copy(command) }
            } else {
                // Бинаря нет — команда вела бы в пустоту. Молчим: скопированная
                // строка, которая не работает, хуже отсутствующей.
                EmptyView()
            }
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        Analytics.claudeSetup(step: "command_copied", client: client.rawValue)
    }
}

/// Одна строка — один клиент.
///
/// Своё `@State` на строку, а не общее на группу: неудача записи в конфиг
/// одного клиента ничего не говорит о другом, и «Попробовать снова» обязано
/// стоять ровно там, где нажали.
private struct MCPClientRow: View {
    @ObservedObject var state: AppState
    let client: MCPClient

    @State private var cell: MCPCellState = .offer
    /// Живёт до следующего нажатия. Это ответ на действие, а не свойство
    /// системы, и переживать открытие настроек ему незачем.
    @State private var writeFailed = false

    var body: some View {
        SettingsCell(client.rowTitle, subtitle: cell.subtitle(for: client)) {
            control
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in refresh() }
    }

    @ViewBuilder
    private var control: some View {
        if let title = cell.actionTitle {
            // Акцент — на том, что ещё не подключено; у подключённого тихая
            // галочка. «Попробовать снова» после отказа записи — тоже акцент:
            // это единственное, что осталось сделать в строке.
            SettingsButton(title, prominent: true) { connect() }
        } else if cell.showsCheckmark {
            SettingsCheck()
        } else {
            // У «не установлен» справа нет ничего. Кнопки «Скачать» здесь не
            // будет: нажимать нам не на что, а уводить человека из настроек в
            // браузер за чужим приложением — не наше дело и не наш приём.
            EmptyView()
        }
    }

    private func connect() {
        writeFailed = !MCPConnector.connect(client)
        refresh()
    }

    private func refresh() {
#if GALLERY
        if let forced = state.galleryMCPCellOverride, forced.client == client {
            cell = forced.state
            return
        }
#endif
        cell = MCPConnector.cellState(for: client, lastWriteFailed: writeFailed)
    }
}

// MARK: - Хранилище

/// Где лежат файлы и сколько занимают.
///
/// Имя группы владелец оставил как было. Внутри изменилось одно, зато важное:
/// путь больше не набирают руками. Папка — это её имя, её путь второй строкой и
/// кнопка «Изменить…»; текстовое поле пути ничего не настраивало, а только
/// давало опечатке шанс — нормализация живёт на чтении
/// (`ArchivePath.normalized`), и сломанный путь выглядел как рабочий.
private struct StorageSettingsGroup: View {
    @ObservedObject var state: AppState
    @AppStorage("markdownOutputFormat") private var markdownOutputFormat = MarkdownOutputFormat.simple.rawValue
    @AppStorage("meetingsPath") private var meetingsPath = ""
    @AppStorage("recordingsPath") private var recordingsPath = ""
    @AppStorage("peoplePagesPath") private var peoplePagesPath = ""
    @AppStorage("audioRetentionMode") private var audioRetentionMode = AudioRetentionMode.afterTranscript.rawValue
    @State private var showingClearConfirm = false

    /// Сколько заберёт «Очистить» — не то же, что «Аудио на диске»: у идущей
    /// записи и у нерасшифрованной встречи звук не забирают (`AudioReclaim`).
    private var reclaimable: Int64 { state.storageReclaimableBytes }

    var body: some View {
        SettingsGroup("Хранилище") {
            SettingsCell("Формат заметок", subtitle: formatHelp) {
                Picker("", selection: $markdownOutputFormat) {
                    ForEach(MarkdownOutputFormat.allCases) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .onChange(of: markdownOutputFormat) { _, val in
                Preferences.shared.markdownOutputFormat =
                    MarkdownOutputFormat(rawValue: val) ?? .simple
            }

            pathCell("Папка заметок", path: $meetingsPath) {
                Preferences.shared.meetingsPath = meetingsPath
            }
            pathCell("Папка записей", path: $recordingsPath) {
                Preferences.shared.recordingsPath = recordingsPath
            }
            if markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue {
                // Единственная папка, у которой есть пустое состояние: без неё
                // wikilinks просто не появятся. Поэтому и подпись у неё не про
                // путь, а про то, что даёт её выбор.
                SettingsCell(
                    "Страницы людей",
                    subtitle: peoplePagesPath.isEmpty
                        ? "Имена спикеров станут [[wikilinks]]"
                        : peoplePagesPath,
                    tone: peoplePagesPath.isEmpty ? .help : .value
                ) {
                    SettingsButton(peoplePagesPath.isEmpty ? "Выбрать…" : "Изменить…") {
                        choose($peoplePagesPath) { Preferences.shared.peoplePagesPath = peoplePagesPath }
                    }
                }
            }

            // Подписи под строкой у режима нет: два пункта по слову-двум
            // объясняют себя сами, а абзац под ними объяснял бы выбор, которого
            // больше не осталось.
            SettingsCell("Хранить аудио") {
                Picker("", selection: $audioRetentionMode) {
                    ForEach(AudioRetentionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .onChange(of: audioRetentionMode) { _, val in
                // Через `Preferences`, а не только `@AppStorage`: там живёт
                // разбор записанного (`AudioRetention.storedMode`), и выбор
                // обязан проходить через то же место, что и чтение.
                Preferences.shared.audioRetentionMode =
                    AudioRetentionMode(rawValue: val) ?? .afterTranscript
            }

            // Порога нет и у кнопки: пока чистить нечего, её просто нет, а не
            // «есть, но не работает».
            SettingsCell("Аудио на диске") {
                HStack(spacing: Tokens.Space.s8) {
                    SettingsValue(Self.bytes(state.storageLibraryBytes))
                    if reclaimable > 0 {
                        SettingsButton("Очистить…") { showingClearConfirm = true }
                    }
                }
            }

            // «Стереть человека» двери не получает намеренно (решение владельца
            // 2026-08-17): постоянных спикеров в продукте пока нет, а стирание
            // по имени не согласуется по падежу («с Иваном» → «с Участник») и
            // сливает двух стёртых в одного. Механизм есть и покрыт тестами
            // (`AppState.erasePerson`), поверхность появится вместе с людьми.
        }
        // Подтверждение необратимого действия, начатого человеком: он за
        // клавиатурой, окно возможности — его же клик. Единственная роль, в
        // которой `design/notifications.md` §5 разрешает модалку.
        .confirmationDialog(
            "Удалить аудио встреч?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                state.deleteAllReclaimableAudio()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Освободится \(Self.bytes(reclaimable)). Расшифровки и саммари останутся, аудио вернуть будет нельзя.")
        }
        .onAppear {
            if meetingsPath.isEmpty { meetingsPath = Preferences.shared.meetingsPath }
            if recordingsPath.isEmpty { recordingsPath = Preferences.shared.recordingsPath }
            state.refreshStorageUsage()
        }
    }

    private var formatHelp: String {
        markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue
            ? "YAML и [[wikilinks]]; старые файлы не меняются"
            : "Читаемый markdown для обмена"
    }

    /// Папка: имя строкой, путь второй строкой, «Изменить…» справа.
    ///
    /// Путь — это значение, а не пояснение, поэтому тон `.value`: одна строка,
    /// обрезается серединой. У пути важны и начало (какой диск), и хвост (какая
    /// папка), а середина — как раз то, что человек и так знает.
    private func pathCell(
        _ title: String,
        path: Binding<String>,
        onUpdate: @escaping () -> Void
    ) -> some View {
        // Пустой путь — не пустая строка под заголовком, а её отсутствие: до
        // `onAppear` значение ещё не прочитано из `Preferences`, и пустая
        // вторая строка растила бы ячейку молча.
        SettingsCell(
            title,
            subtitle: path.wrappedValue.isEmpty ? nil : path.wrappedValue,
            tone: .value
        ) {
            SettingsButton("Изменить…") { choose(path, onUpdate: onUpdate) }
        }
    }

    private func choose(_ path: Binding<String>, onUpdate: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
            onUpdate()
        }
    }

    /// Байты человеку. `ByteCountFormatter` ставит между числом и единицей
    /// обычный пробел (U+0020), а в тексте диалога он попадает под перенос —
    /// «1,64» на одной строке, «ГБ» на следующей. `principles.md` §6 это
    /// запрещает, и починить это можно только здесь: строку собирает система.
    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

// MARK: - О программе

/// Приложение о себе — и один тумблер, который тоже про него.
///
/// Аналитика приехала сюда из распущенной «Приватности» (решение владельца
/// 2026-08-20): она не про архив и не про то, кто его читает, — она про само
/// приложение, как версия и обновления. Заголовок строки — глагол, потому что
/// это единственная строка группы, где человек что-то решает.
private struct AboutSettingsGroup: View {
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    var body: some View {
        SettingsGroup("О программе") {
            SettingsCell(
                "Отправлять аналитику",
                subtitle: "Только события приложения, без личных данных"
            ) {
                SettingsSwitch(isOn: $analyticsEnabled)
            }
            .onChange(of: analyticsEnabled) { _, on in
                Analytics.setEnabled(on)
            }

            SettingsCell("Версия") {
                SettingsValue(LoginItem.appVersionString)
            }
            SettingsCell("Обновления") {
                SettingsButton(
                    "Проверить обновления…",
                    enabled: SparkleUpdater.shared.canCheckForUpdates
                ) {
                    SparkleUpdater.shared.checkForUpdates()
                }
            }
        }
    }
}

// MARK: - Launch at login (native SMAppService) + version

/// Thin wrapper over `SMAppService.mainApp` so the Recording group can offer a
/// native "Launch at login" toggle. macOS surfaces approval/management under
/// System Settings → General → Login Items; we never write a LaunchAgent plist.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
