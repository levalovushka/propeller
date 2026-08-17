import SwiftUI
import PropellerUI
import PropellerPure
import ServiceManagement

/// Настройки, как их видит человек, — состояние правой панели.
///
/// Что здесь изменилось против окна с пятью вкладками, и почему:
///
/// - **Вкладок нет.** Пять вкладок на полторы страницы утверждали, что эти
///   наборы нельзя показывать вместе. Можно: теперь это один столбец групп, и
///   найти настройку — значит проскроллить, а не вспомнить вкладку.
/// - **Раздела «Аудио» нет.** Он предлагал выключить захват системного звука —
///   то есть вторую сторону разговора. Приложение без неё не работает, так что
///   это был не выбор, а способ сломать продукт (тот же довод, что снял «Выкл»
///   из провайдеров саммари).
/// - **«Расшифровка» и «Саммари» — одна группа «Нейросети».** Обе про модели, и
///   обе настраивают одно и то же: во что превратится записанный звук.
/// - **Ключи и модели контекстны.** Показываем настройки того провайдера,
///   который выбран, а не всех трёх сразу.
/// - **Описаний стало меньше.** Абзац под каждым переключателем — это не помощь,
///   а шум; остались те, без которых настройка непонятна, и они в одну строку.
/// - **Показаний прибора нет.** Ушли «Движок расшифровки», «Состояние» детектора
///   и кнопка «Проверить» у Ollama: настройка — это то, что человек меняет, а не
///   то, что он у приложения выспрашивает. Единственное оставшееся состояние —
///   отвечает ли локальный движок — стоит второй строкой у выбора модели, само.
///
/// Вёрстка — `PropellerUI/SettingsKit.swift`. Здесь только то, что читает и
/// пишет `Preferences`, `AppState` и Keychain.
struct SettingsPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsColumn {
            GeneralSettingsGroup(state: state)
            AnalyticsSettingsGroup()
            ModelsSettingsGroup(state: state)
            ClaudeSettingsGroup(state: state)
            StorageSettingsGroup(state: state)
            AboutSettingsGroup()
        }
    }
}

// MARK: - Основное

/// Запуск и автозапись — два выключателя, оба про то, когда приложение
/// оживает само.
///
/// Строки «Показывать встречи из Календаря» здесь больше нет. Она обещала
/// список, которого в интерфейсе нет с 2026-08-04 — секция «Скоро» удалена,
/// рельс и есть список. Календарь при этом продолжает работать: он **называет**
/// записи (`CalendarService.suggestedRecordingTitle`), а включается там, где о
/// нём и спрашивают, — блоком у подошвы рельса (`SetupPromptMachine`).
private struct GeneralSettingsGroup: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginError: String?
    @AppStorage("autoRecordMode") private var autoRecordMode = AutoRecordMode.auto.rawValue
    @AppStorage("menuBarIconVisible") private var menuBarIconVisible = true

    var body: some View {
        SettingsGroup("Основное") {
            SettingsCell(
                "Запускать Propeller при входе",
                // Единственная строка, которая здесь появляется: отказ системы.
                // Она не описывает настройку, она отвечает на нажатие.
                subtitle: launchAtLoginError
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

            // Zoom назван поимённо: у Толка сигнала «идёт звонок» нет вовсе, и
            // обещать здесь «звонок» вообще значило бы обещать старт, который
            // не наступит.
            SettingsCell(
                "Автоматическая запись",
                subtitle: "Стартует и заканчивается вместе со звонком в\u{00A0}Zoom"
            ) {
                SettingsSwitch(isOn: autoRecord)
            }
            .onChange(of: autoRecordMode) { _, val in
                Preferences.shared.autoRecordMode = AutoRecordMode(rawValue: val) ?? .auto
                state.applyAutoRecordMode()
            }

            // Выключатель живёт здесь, потому что вернуть иконку можно только
            // отсюда: в поповере, которого без неё не будет, доступно лишь
            // «Скрыть». Сцена читает тот же ключ (`MenuBarExtra(isInserted:)`).
            SettingsCell("Показывать Propeller в меню баре") {
                SettingsSwitch(isOn: $menuBarIconVisible)
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

// MARK: - Аналитика

private struct AnalyticsSettingsGroup: View {
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    var body: some View {
        SettingsGroup("Аналитика") {
            SettingsCell(
                "Отправлять анонимную телеметрию",
                subtitle: "Только события приложения — без личных данных"
            ) {
                SettingsSwitch(isOn: $analyticsEnabled)
            }
            .onChange(of: analyticsEnabled) { _, on in
                Analytics.setEnabled(on)
            }
        }
    }
}

// Группы «Автозапись звонков» больше нет. В ней остался один выключатель, и
// заголовок группы повторял его же название; сам выключатель переехал в
// «Основное», к запуску при входе — оба про то, когда приложение оживает само.
// Строка «Состояние» с ручной пробой детектора удалена: приложение и так
// проверяет это само, а показание прибора в настройках — не настройка.

// MARK: - Нейросети

/// Расшифровка и саммари в одной группе.
///
/// Их разделяло только то, что это были две вкладки. Настраивают они одно: во
/// что превращается записанный звук — сначала в текст, потом в конспект.
private struct ModelsSettingsGroup: View {
    @ObservedObject var state: AppState
    @AppStorage("domainTerms") private var domainTerms = ""
    @AppStorage("recapProvider") private var recapProvider = RecapProviderKind.ollama.rawValue
    @AppStorage("recapOpenAIModel") private var recapOpenAIModel = "gpt-4o-mini"
    @AppStorage("recapClaudeModel") private var recapClaudeModel = "claude-sonnet-4-5"
    @State private var recapPrompt: String = Preferences.shared.recapPrompt
    // Пустые, а заполняются в `onAppear`. Инициализатор свойства выполняется на
    // *каждой* пересборке структуры, даже когда `@State` его результат уже
    // игнорирует, — а это поход в Keychain, и на открытых настройках во время
    // записи он случался бы каждую секунду вместе с тиком таймера.
    @State private var openAIKey: String = ""
    @State private var claudeKey: String = ""
    @State private var ollamaReachable: Bool? = nil
    @State private var restartStatus: String?
    @State private var pendingRestart: DispatchWorkItem?

    var body: some View {
        SettingsGroup("Нейросети") {
            // Движка расшифровки здесь нет: он ровно один, выбрать другой
            // нельзя, а строка без выбора — не настройка.
            SettingsStack(
                "Словарь",
                subtitle: "Добавь англицизмы, которые нейросеть должна понимать идеально"
            ) {
                VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                    SettingsField("напр. Газпромнефть, Аэрофлот", text: $domainTerms)
                    if let restartStatus {
                        Text(restartStatus)
                            .typo(Tokens.Settings.Typo.subtitle)
                            .foregroundStyle(Tokens.Settings.subtitle)
                    }
                }
            }
            .onChange(of: domainTerms) { _, val in
                Preferences.shared.domainTerms = val
                scheduleRestart()
            }

            // Состояние движка — второй строкой у самого выбора: вопрос «кто
            // пишет саммари» и вопрос «отвечает ли он» — один вопрос.
            SettingsCell("Модель для саммари", subtitle: providerStatus) {
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

            // «Сбросить промпт» здесь больше нет, и замены ей не нужно: пустое
            // поле **и есть** сброс — `Preferences.recapPrompt` отдаёт дефолт,
            // когда сохранённого нет. Кнопка была третьим способом сказать то же
            // самое, что ⌘A и Delete.
            SettingsStack("Промпт") {
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
            recapOpenAIModel = Preferences.shared.recapOpenAIModel
            recapClaudeModel = Preferences.shared.recapClaudeModel
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
        text: Binding<String>,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        SettingsStack(title) {
            SettingsField(placeholder, text: text)
        }
        .onChange(of: text.wrappedValue) { _, val in onCommit(val) }
    }

    /// Что сказать про выбранного провайдера. Про облачные — ничего: ключ либо
    /// есть, либо нет, и об этом говорит само поле ключа. Про локальный есть
    /// что: он либо отвечает, либо ещё едет, либо не поднялся.
    private var providerStatus: String? {
        guard provider == .ollama else { return nil }
        // Пока модель едет — процент. Полосы загрузки под этой строкой больше
        // нет, и это единственное место, где про загрузку вообще сказано.
        if let frac = state.ollamaSetupProgress {
            return "Скачиваем модель… \(Int(frac * 100))%"
        }
        switch ollamaReachable {
        case true: return "Отвечает на\u{00A0}:11434"
        case false: return "Не запущен"
        case nil: return "Проверяем…"
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

// MARK: - Claude

/// Одна ячейка, одна кнопка, и ни одного диалога.
///
/// Конфиг Клода можно отредактировать руками — сегодня это единственный способ,
/// и он не работает: путь надо знать. Здесь всё, что от человека требуется, —
/// нажать; остальное (найти Claude Desktop, сделать копию его конфига, дописать
/// в него запись) делает `ClaudeConnector`.
///
/// **Состояние выводится при каждом открытии, а не хранится.** Файл чужой: его
/// может переписать сам Claude Desktop, и сохранённое «подключено» разошлось бы
/// с правдой молча. Плюс перечитывание на возврате в приложение — человек уходит
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
    @State private var cell: ClaudeCellState = .offer
    /// Живёт до следующего нажатия. Это ответ на действие, а не свойство
    /// системы, и переживать открытие настроек ему незачем.
    @State private var writeFailed = false

    var body: some View {
        // Группа — «MCP», а не «Claude»: подключение к модели через MCP это
        // способ, а не имя, и рядом с Клодом со временем встанут другие клиенты.
        SettingsGroup("MCP") {
            SettingsCell(ClaudeCellState.rowTitle, subtitle: cell.subtitle) {
                control
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in refresh() }
    }

    @ViewBuilder
    private var control: some View {
        if let title = cell.actionTitle {
            SettingsButton(title) { connect() }
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
        writeFailed = !ClaudeConnector.connect()
        refresh()
    }

    private func refresh() {
#if GALLERY
        if let forced = state.galleryClaudeCellOverride {
            cell = forced
            return
        }
#endif
        cell = ClaudeConnector.cellState(lastWriteFailed: writeFailed)
    }
}

// MARK: - Хранилище

private struct StorageSettingsGroup: View {
    @ObservedObject var state: AppState
    @AppStorage("markdownOutputFormat") private var markdownOutputFormat = MarkdownOutputFormat.simple.rawValue
    @AppStorage("meetingsPath") private var meetingsPath = ""
    @AppStorage("recordingsPath") private var recordingsPath = ""
    @AppStorage("peoplePagesPath") private var peoplePagesPath = ""
    @AppStorage("audioRetentionMode") private var audioRetentionMode = AudioRetentionMode.keep.rawValue
    @AppStorage("audioRetentionDays") private var audioRetentionDays = AudioRetention.defaultDays
    @State private var showingClearConfirm = false
    @State private var personToErase = ""
    @State private var showingEraseConfirm = false
    @State private var personErasureResult: String?

    /// Сколько заберёт «Очистить» — не то же, что «Аудио на диске»: у идущей
    /// записи и у нерасшифрованной встречи звук не забирают (`AudioReclaim`).
    private var reclaimable: Int64 { state.storageReclaimableBytes }

    var body: some View {
        SettingsGroup("Хранилище") {
            SettingsCell("Формат Markdown", subtitle: formatHelp) {
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

            pathCell("Записи", path: $recordingsPath) {
                Preferences.shared.recordingsPath = recordingsPath
            }
            pathCell("Заметки", path: $meetingsPath) {
                Preferences.shared.meetingsPath = meetingsPath
            }
            if markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue {
                pathCell(
                    "Страницы людей",
                    subtitle: "Папка vault Obsidian со страницами людей. Если задана, имена спикеров ссылаются через [[wikilinks]].",
                    path: $peoplePagesPath
                ) {
                    Preferences.shared.peoplePagesPath = peoplePagesPath
                }
            }

            // Порога нет и у кнопки: пока чистить нечего, её просто нет, а не
            // «есть, но не работает».
            SettingsCell("Аудио на диске") {
                HStack(spacing: Tokens.Space.s8) {
                    SettingsValue(Self.bytes(state.storageLibraryBytes))
                    if reclaimable > 0 {
                        SettingsButton("Очистить") { showingClearConfirm = true }
                    }
                }
            }

            SettingsCell("Хранить аудио", subtitle: retentionHelp) {
                HStack(spacing: Tokens.Space.s8) {
                    Picker("", selection: $audioRetentionMode) {
                        ForEach(AudioRetentionMode.allCases) { mode in
                            Text(Self.retentionTitle(mode)).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if audioRetentionMode == AudioRetentionMode.afterDays.rawValue {
                        Stepper(
                            "\(audioRetentionDays) дн.",
                            value: $audioRetentionDays,
                            in: AudioRetention.dayRange
                        )
                        .fixedSize()
                    }
                }
            }
            .onChange(of: audioRetentionDays) { _, val in
                // Через `Preferences`, а не только `@AppStorage`: там живёт
                // приведение к допустимому диапазону, и записанное руками в
                // defaults число обязано проходить через него.
                Preferences.shared.audioRetentionDays = val
            }

            SettingsStack(
                "Стереть человека",
                subtitle: "Имя уходит из всех встреч: метки реплик, конспекты, заголовки, заметки, приглашённые. Записи и расшифровки остаются — уходит атрибуция, а не разговор. Вернуть нельзя."
            ) {
                HStack(spacing: Tokens.Space.s8) {
                    SettingsField("Имя и фамилия", text: $personToErase)
                    if !personToErase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SettingsButton("Стереть") { showingEraseConfirm = true }
                    }
                }
                if let personErasureResult {
                    SettingsValue(personErasureResult)
                }
            }
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
        .confirmationDialog(
            "Стереть «\(personToErase)» из всех встреч?",
            isPresented: $showingEraseConfirm,
            titleVisibility: .visible
        ) {
            Button("Стереть", role: .destructive) { erasePerson() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Имя исчезнет из расшифровок, конспектов, заголовков и заметок по всему архиву. Отменить это нечем.")
        }
        .onAppear {
            if meetingsPath.isEmpty { meetingsPath = Preferences.shared.meetingsPath }
            if recordingsPath.isEmpty { recordingsPath = Preferences.shared.recordingsPath }
            state.refreshStorageUsage()
        }
    }

    private var formatHelp: String {
        markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue
            ? "YAML frontmatter + [[wikilinks]] для vault Obsidian."
            : "Читаемый markdown: заголовок, участники, расшифровка. По умолчанию для обмена."
    }

    private var retentionHelp: String {
        switch AudioRetentionMode(rawValue: audioRetentionMode) ?? .keep {
        case .keep:
            return "Аудио не удаляется само. Освободить место можно кнопкой выше."
        case .afterTranscript:
            return "Звук уходит, как только расшифровка и спикеры готовы. Слушать встречу потом будет нечем."
        case .afterDays:
            return "Через \(audioRetentionDays) дн. звук уходит у встреч, которым он больше не нужен. Расшифровки и конспекты остаются."
        }
    }

    private static func retentionTitle(_ mode: AudioRetentionMode) -> String {
        switch mode {
        case .keep:            return "Всегда"
        case .afterTranscript: return "До расшифровки"
        case .afterDays:       return "Столько дней"
        }
    }

    private func erasePerson() {
        let name = personToErase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let report = state.erasePerson(named: name)
        // Показание, а не тост: результат живёт в той же строке, где действие, и
        // говорит ровно то, что произошло. У неполного стирания это перечисление
        // файлов, а не «что-то пошло не так».
        personErasureResult = report.isComplete
            ? "Стёрто во встречах: \(report.entriesChanged)"
            : "Осталось в: \(report.remaining.joined(separator: ", "))"
        if report.isComplete { personToErase = "" }
        state.refreshStorageUsage()
    }

    private func pathCell(
        _ title: String,
        subtitle: String? = nil,
        path: Binding<String>,
        onUpdate: @escaping () -> Void
    ) -> some View {
        SettingsStack(title, subtitle: subtitle) {
            HStack(spacing: Tokens.Space.s8) {
                SettingsField(title, text: path)
                    .onChange(of: path.wrappedValue) { _, _ in onUpdate() }
                SettingsButton("Выбрать") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                        onUpdate()
                    }
                }
            }
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

private struct AboutSettingsGroup: View {
    var body: some View {
        SettingsGroup("О программе") {
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

/// Thin wrapper over `SMAppService.mainApp` so the General group can offer a
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
