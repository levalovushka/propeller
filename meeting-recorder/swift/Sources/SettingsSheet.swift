import SwiftUI
import PropellerUI
import PropellerPure
import ServiceManagement

/// Native Settings window (⌘,) with talat-style sub-sections, built on the
/// standard macOS settings TabView.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("Основное", systemImage: "gearshape") }
            AudioSettingsPane()
                .tabItem { Label("Аудио", systemImage: "speaker.wave.2") }
            TranscriptionSettingsPane()
                .tabItem { Label("Расшифровка", systemImage: "waveform") }
            RecapSettingsPane()
                .tabItem { Label("Саммари", systemImage: "sparkles") }
            ExportSettingsPane()
                .tabItem { Label("Экспорт", systemImage: "square.and.arrow.up" ) }
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true
    @AppStorage("autoRecordMode") private var autoRecordMode = AutoRecordMode.auto.rawValue
    @State private var detectionSnapshot = MeetingDetector.shared.snapshot
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginError: String?
    @AppStorage("calendarEnabled") private var calendarEnabled = false

    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускать Propeller при входе", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, want in
                        do {
                            try LoginItem.setEnabled(want)
                            launchAtLoginError = nil
                        } catch {
                            // Revert the toggle to the real state and surface the reason.
                            launchAtLogin = LoginItem.isEnabled
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                Text("Propeller стартует при входе в систему. Управление — в «Объекты входа» в Системных настройках.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(.orange)
                }
            }

            Section("Календарь") {
                Toggle("Показывать встречи из Календаря", isOn: $calendarEnabled)
                    .onChange(of: calendarEnabled) { _, on in
                        Preferences.shared.calendarEnabled = on
                        if on {
                            Task { await CalendarService.shared.enableAndLoad() }
                        } else {
                            CalendarService.shared.events = []
                        }
                    }
                Text("Читает macOS Календарь (включая Google/Exchange из Системных настроек → Интернет-аккаунты). Данные не покидают Mac.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }

            Section("Обработка") {
                Text("После стопа сразу идут расшифровка (gigastt / GigaAM), сохранение и саммари. Модель речи скачивается при первой расшифровке — прогресс в статус-баре.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }

            Section("Аналитика") {
                Toggle("Отправлять анонимную телеметрию", isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { _, on in
                        Analytics.setEnabled(on)
                    }
                Text("Только события воронки (запись, ASR, саммари, поиск). Без транскриптов, путей и названий. Для быстрых итераций dogfood.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }

            Section("Автозапись звонков") {
                Picker("Когда начинается звонок", selection: $autoRecordMode) {
                    ForEach(AutoRecordMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: autoRecordMode) { _, val in
                    Preferences.shared.autoRecordMode =
                        AutoRecordMode(rawValue: val) ?? .auto
                    appState.applyAutoRecordMode()
                }
                Text(autoRecordModeHelp)
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)

                LabeledContent("Статус") {
                    HStack(spacing: 8) {
                        Text(meetingProbeLabel(detectionSnapshot))
                            .foregroundStyle(detectionSnapshot.inMeeting ? .green : .secondary)
                        Button("Проверить") {
                            detectionSnapshot = MeetingDetector.shared.probe()
                        }
                        .controlSize(.small)
                    }
                }

            }

            Section("О программе") {
                LabeledContent("Версия", value: LoginItem.appVersionString)
                Button("Проверить обновления…") {
                    SparkleUpdater.shared.checkForUpdates()
                }
                .disabled(!SparkleUpdater.shared.canCheckForUpdates)
                Text("Обновления с GitHub Releases (Sparkle). Первый запуск: ПКМ → Открыть, пока нет Developer ID.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            detectionSnapshot = MeetingDetector.shared.probe()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private var autoRecordModeHelp: String {
        switch AutoRecordMode(rawValue: autoRecordMode) ?? .auto {
        case .off:
            return "Звонки игнорируются. Запись — вручную."
        case .auto:
            // Names Zoom alone: Толк has no signal that says a call is on, so
            // promising it here meant promising a start that never comes.
            return "Запись стартует при обнаружении звонка Zoom — без подтверждения. В уведомлении можно отказаться; остановить можно из меню или приложения. Запись останавливается с концом звонка."
        }
    }

    /// Names the platform it actually found — with more than one supported,
    /// "Zoom: ожидание" while sitting in Толк would be actively misleading.
    private func meetingProbeLabel(_ snap: MeetingSnapshot) -> String {
        if let platformID = snap.platformID {
            let name = MeetingPlatform.platform(id: platformID)?.displayName ?? platformID
            return "\(name): идёт звонок (\(snap.signals.joined(separator: ", ")))"
        }
        if snap.appRunning { return "Приложение запущено, звонка нет" }
        return "Ни одно приложение для созвонов не запущено"
    }
}

// MARK: - Audio

private struct AudioSettingsPane: View {
    @AppStorage("captureSystemAudio") private var captureSystemAudio = true

    var body: some View {
        Form {
            Section("Захват") {
                Toggle("Захватывать системный звук", isOn: $captureSystemAudio)
                    .onChange(of: captureSystemAudio) { _, val in Preferences.shared.captureSystemAudio = val }
                Text("Вторую сторону звонка пишет тап Core Audio — отдельного разрешения macOS для этого не спрашивает. Выключено — в\u{00A0}записи только микрофон.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

private struct TranscriptionSettingsPane: View {
    @AppStorage("domainTerms") private var domainTerms = ""
    @State private var restartStatus: String?
    @State private var pendingRestart: DispatchWorkItem?

    var body: some View {
        Form {
            Section("Движок") {
                LabeledContent("Движок", value: TranscriptionService.engineDescription)
                Text("Бинарник gigastt уже в приложении; модель GigaAM в комплект не входит — скачивается при первой расшифровке (прогресс в статус-баре). Только русский.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }

            Section("Словарь") {
                TextField("Свои термины", text: $domainTerms, prompt: Text("напр. Газпромнефть, Аэрофлот"))
                    .onChange(of: domainTerms) { _, val in
                        Preferences.shared.domainTerms = val
                        scheduleRestart()
                    }
                Text("В приложении уже есть словарь рабочего жаргона и англицизмов (\(BuiltinHotwords.terms.count) терминов) — он всегда включён. Здесь добавь своё через запятую: клиентов, фамилии, названия проектов. Применится к следующей расшифровке, распознаватель перезапустится через пару секунд.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
                if let restartStatus {
                    Text(restartStatus)
                        .typo(Tokens.Typography.Label.xsRegular)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
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
                    await MainActor.run { restartStatus = "Ошибка перезапуска: \(error.localizedDescription)" }
                }
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - Recap (LLM)

private struct RecapSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("recapProvider") private var recapProvider = RecapProviderKind.auto.rawValue
    @AppStorage("recapOllamaModel") private var recapOllamaModel = Preferences.defaultRecapModel
    @AppStorage("recapOpenAIModel") private var recapOpenAIModel = "gpt-4o-mini"
    @AppStorage("recapClaudeModel") private var recapClaudeModel = "claude-sonnet-4-5"
    @State private var recapPrompt: String = Preferences.shared.recapPrompt
    @State private var openAIKey: String = Preferences.shared.openAIAPIKey ?? ""
    @State private var claudeKey: String = Preferences.shared.claudeAPIKey ?? ""
    @State private var ollamaReachable: Bool? = nil
    @State private var isInstalling = false

    var body: some View {
        Form {
            Section("Провайдер") {
                Picker("Провайдер", selection: $recapProvider) {
                    ForEach(RecapProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                .onChange(of: recapProvider) { _, val in
                    Preferences.shared.recapProvider =
                        RecapProviderKind(rawValue: val) ?? .auto
                    // Meetings that were waiting on a summary can go now — and
                    // ones that gave up waiting are un-parked.
                    appState.summaryProviderChanged()
                }

                LabeledContent("Ollama") {
                    HStack(spacing: 8) {
                        Text(ollamaStatusText)
                            .foregroundStyle(ollamaReachable == true ? .green : .secondary)
                        Button("Проверить") {
                            Task {
                                await OllamaSidecar.shared.ensureServerRunning()
                                ollamaReachable = await RecapService.shared.probeOllama()
                                // Pressed by hand, so it applies at once rather
                                // than through the keystroke debounce.
                                appState.applySummaryProviderChange()
                            }
                        }
                        .controlSize(.small)
                        // The one place the fetch is still pressable by hand, and
                        // deliberately phrased as what it is: the app already does
                        // this on every launch, so this is for the case where
                        // somebody wants it *now* rather than in twenty seconds.
                        if appState.localRecapModelReady != true {
                            Button(appState.ollamaSetupProgress != nil
                                   ? "Скачиваем…" : "Проверить и починить") {
                                Task { await appState.ensureSummaryModel() }
                                isInstalling = true
                            }
                            .controlSize(.small)
                            .disabled(appState.ollamaSetupProgress != nil)
                        }
                    }
                    // On the HStack, not the button: the button disappears once
                    // the model lands, and these still have to settle state.
                    .onChange(of: appState.ollamaSetupProgress) { _, frac in
                        if frac == nil { isInstalling = false }
                    }
                    .onChange(of: appState.ollamaSetupMessage) { _, msg in
                        if msg == "Модель готова" {
                            ollamaReachable = true
                            isInstalling = false
                            appState.refreshLocalRecapModelState()
                        }
                    }
                }
                if let frac = appState.ollamaSetupProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: frac)
                        Text(appState.ollamaSetupMessage.isEmpty
                             ? "Скачиваем… \(Int(frac * 100))%"
                             : appState.ollamaSetupMessage)
                            .typo(Tokens.Typography.Label.smRegular)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if recapProvider == RecapProviderKind.ollama.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("Ollama") {
                    TextField("Модель", text: $recapOllamaModel, prompt: Text(Preferences.defaultRecapModel))
                        .onChange(of: recapOllamaModel) { _, val in
                            Preferences.shared.recapOllamaModel = val
                            appState.summaryProviderChanged()
                        }
                    Text("Propeller сам скачивает движок Ollama и модель в Application Support — ставить Ollama.app не нужно.")
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(.secondary)
                }
            }

            if recapProvider == RecapProviderKind.openai.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("OpenAI") {
                    SecureField("API-ключ", text: $openAIKey, prompt: Text("sk-…"))
                        .onChange(of: openAIKey) { _, val in
                            Preferences.shared.openAIAPIKey = val
                            appState.summaryProviderChanged()
                        }
                    TextField("Модель", text: $recapOpenAIModel, prompt: Text("gpt-4o-mini"))
                        .onChange(of: recapOpenAIModel) { _, val in
                            Preferences.shared.recapOpenAIModel = val
                        }
                    Text("Ключ хранится в Keychain.")
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(.secondary)
                }
            }

            if recapProvider == RecapProviderKind.claude.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("Claude") {
                    SecureField("API-ключ", text: $claudeKey, prompt: Text("sk-ant-…"))
                        .onChange(of: claudeKey) { _, val in
                            Preferences.shared.claudeAPIKey = val
                            appState.summaryProviderChanged()
                        }
                    TextField("Модель", text: $recapClaudeModel, prompt: Text("claude-sonnet-4-5"))
                        .onChange(of: recapClaudeModel) { _, val in
                            Preferences.shared.recapClaudeModel = val
                        }
                    Text("Ключ хранится в Keychain.")
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Промпт") {
                TextEditor(text: $recapPrompt)
                    .typo(Tokens.Typography.Label.mdRegular)
                    .frame(minHeight: 110, maxHeight: 160)
                    .onChange(of: recapPrompt) { _, val in
                        Preferences.shared.recapPrompt = val
                    }
                Button("Сбросить промпт") {
                    recapPrompt = RecapService.defaultPrompt
                    Preferences.shared.recapPrompt = RecapService.defaultPrompt
                }
                .controlSize(.small)
                Text("Без локальной модели и без API-ключа запись и расшифровка работают как обычно — пропускается только саммари, с подсказкой в карточке встречи.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshLocalRecapModelState()
            recapPrompt = Preferences.shared.recapPrompt
            openAIKey = Preferences.shared.openAIAPIKey ?? ""
            claudeKey = Preferences.shared.claudeAPIKey ?? ""
            recapOllamaModel = Preferences.shared.recapOllamaModel
            recapOpenAIModel = Preferences.shared.recapOpenAIModel
            recapClaudeModel = Preferences.shared.recapClaudeModel
            Task { ollamaReachable = await RecapService.shared.probeOllama() }
        }
    }

    private var ollamaStatusText: String {
        switch ollamaReachable {
        case true: return "доступен на :11434"
        case false: return "не запущен"
        case nil: return "проверка…"
        }
    }
}

// MARK: - Export (output format, storage, retention)

private struct ExportSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.undoManager) private var undoManager
    @AppStorage("markdownOutputFormat") private var markdownOutputFormat = MarkdownOutputFormat.simple.rawValue
    @AppStorage("meetingsPath") private var meetingsPath = ""
    @AppStorage("recordingsPath") private var recordingsPath = ""
    @AppStorage("peoplePagesPath") private var peoplePagesPath = ""

    var body: some View {
        Form {
            Section("Формат Markdown") {
                Picker("Формат", selection: $markdownOutputFormat) {
                    ForEach(MarkdownOutputFormat.allCases) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: markdownOutputFormat) { _, val in
                    Preferences.shared.markdownOutputFormat =
                        MarkdownOutputFormat(rawValue: val) ?? .simple
                }
                Text(markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue
                     ? "YAML frontmatter + [[wikilinks]] для vault Obsidian."
                     : "Читаемый markdown: заголовок, участники, расшифровка. По умолчанию для обмена.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
            }

            Section("Хранение") {
                pathField("Записи", path: $recordingsPath) {
                    Preferences.shared.recordingsPath = recordingsPath
                }
                pathField("Заметки", path: $meetingsPath) {
                    Preferences.shared.meetingsPath = meetingsPath
                }
                if markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue {
                    pathField("Страницы людей", path: $peoplePagesPath) {
                        Preferences.shared.peoplePagesPath = peoplePagesPath
                    }
                    Text("Папка vault Obsidian со страницами людей. Если задана, имена спикеров ссылаются через [[wikilinks]].")
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Размер библиотеки") {
                let used = ByteCountFormatter.string(
                    fromByteCount: appState.storageLibraryBytes,
                    countStyle: .file
                )
                LabeledContent("Аудио на диске", value: used)
                // No threshold and no reminder any more: the app does not decide
                // when this becomes a problem. The list below is the tool — it is
                // here, it is sorted, and it is only ever opened on purpose.
                Text("Propeller никогда не удаляет сам. Удаление аудио сохраняет расшифровки и\u{00A0}саммари.")
                    .typo(Tokens.Typography.Label.smRegular)
                    .foregroundStyle(.secondary)
                ForEach(appState.recordingStore.storageNudgeCandidates(limit: 8)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? "Без названия" : entry.title)
                                .lineLimit(1)
                            Text("\(entry.dateFormatted) · \(ByteCountFormatter.string(fromByteCount: appState.recordingStore.byteSize(of: entry), countStyle: .file))")
                                .typo(Tokens.Typography.Label.smRegular)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Удалить аудио") {
                            appState.deleteAudioKeepingMeeting(entry)
                        }
                        .controlSize(.small)
                        Button("Удалить встречу", role: .destructive) {
                            appState.removeRecording(entry, undoManager: undoManager)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if meetingsPath.isEmpty { meetingsPath = Preferences.shared.meetingsPath }
            if recordingsPath.isEmpty { recordingsPath = Preferences.shared.recordingsPath }
            appState.refreshStorageUsage()
        }
    }

    private func pathField(_ label: String, path: Binding<String>, onUpdate: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, text: path)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onChange(of: path.wrappedValue) { _, _ in onUpdate() }
                Button("Выбрать") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                        onUpdate()
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Launch at login (native SMAppService) + version

/// Thin wrapper over `SMAppService.mainApp` so the General pane can offer a
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
