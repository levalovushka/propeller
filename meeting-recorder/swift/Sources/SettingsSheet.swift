import SwiftUI
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
    @AppStorage("zoomAutoRecordMode") private var zoomAutoRecordMode = ZoomAutoRecordMode.auto.rawValue
    @State private var zoomSnap = ZoomMeetingDetector.shared.snapshot
    @State private var hasScreenRecordingPermission = true
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
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
                            CalendarService.shared.upcoming = []
                        }
                    }
                Text("Читает macOS Календарь (включая Google/Exchange из Системных настроек → Интернет-аккаунты). Данные не покидают Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Обработка") {
                Text("После стопа сразу идут расшифровка (gigastt / GigaAM), сохранение и саммари. Модель речи скачивается при первой расшифровке — прогресс в статус-баре.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Аналитика") {
                Toggle("Отправлять анонимную телеметрию", isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { _, on in
                        Analytics.setEnabled(on)
                    }
                Text("Только события воронки (запись, ASR, саммари, поиск). Без транскриптов, путей и названий. Для быстрых итераций dogfood.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Встречи Zoom") {
                Picker("Когда начинается звонок Zoom", selection: $zoomAutoRecordMode) {
                    ForEach(ZoomAutoRecordMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: zoomAutoRecordMode) { _, val in
                    Preferences.shared.zoomAutoRecordMode =
                        ZoomAutoRecordMode(rawValue: val) ?? .auto
                    appState.applyZoomDetectorMode()
                }
                Text(zoomModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Статус") {
                    HStack(spacing: 8) {
                        Text(zoomProbeLabel(zoomSnap))
                            .foregroundStyle(zoomSnap.inMeeting ? .green : .secondary)
                        Button("Проверить") {
                            zoomSnap = ZoomMeetingDetector.shared.probe()
                        }
                        .controlSize(.small)
                    }
                }

                if !hasScreenRecordingPermission {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Обнаружение ограничено — нет разрешения Screen Recording, Propeller не читает заголовок окна Zoom. Остаётся сигнал процесса, он медленнее.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Открыть настройки Screen Recording") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            zoomSnap = ZoomMeetingDetector.shared.probe()
            hasScreenRecordingPermission = ZoomMeetingDetector.hasScreenRecordingPermission()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private var zoomModeHelp: String {
        switch ZoomAutoRecordMode(rawValue: zoomAutoRecordMode) ?? .auto {
        case .off:
            return "Zoom игнорируется. Запись — вручную."
        case .auto:
            return "Запись стартует при обнаружении звонка Zoom — без подтверждения. В уведомлении можно отказаться; остановить можно из меню или приложения. Запись останавливается с концом звонка."
        }
    }

    private func zoomProbeLabel(_ snap: ZoomMeetingSnapshot) -> String {
        if !snap.zoomRunning { return "Zoom: не запущен" }
        if snap.inMeeting {
            let sig = snap.signals.joined(separator: ", ")
            return "Zoom: на встрече (\(sig))"
        }
        return "Zoom: запущен, ожидание"
    }
}

// MARK: - Audio

private struct AudioSettingsPane: View {
    @AppStorage("captureSystemAudio") private var captureSystemAudio = true
    @AppStorage("voiceProcessingEnabled") private var voiceProcessingEnabled = false

    var body: some View {
        Form {
            Section("Захват") {
                Toggle("Захватывать системный звук", isOn: $captureSystemAudio)
                    .onChange(of: captureSystemAudio) { _, val in Preferences.shared.captureSystemAudio = val }
                Text("Нужно разрешение Screen Recording (macOS спросит при первой записи). Если выкл — только микрофон.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Подавлять эхо динамика", isOn: $voiceProcessingEnabled)
                    .onChange(of: voiceProcessingEnabled) { _, val in Preferences.shared.voiceProcessingEnabled = val }
                Text("Микрофон через Apple voice processing (эхо + шум). Для звонков без наушников. По умолчанию выкл — с наушниками не влияет.")
                    .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Словарь") {
                TextField("Свои термины", text: $domainTerms, prompt: Text("напр. Газпромнефть, Аэрофлот"))
                    .onChange(of: domainTerms) { _, val in
                        Preferences.shared.domainTerms = val
                        scheduleRestart()
                    }
                Text("В приложении уже есть словарь рабочего жаргона и англицизмов (\(BuiltinHotwords.terms.count) терминов) — он всегда включён. Здесь добавь своё через запятую: клиентов, фамилии, названия проектов. Применится к следующей расшифровке, распознаватель перезапустится через пару секунд.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let restartStatus {
                    Text(restartStatus)
                        .font(.caption2)
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
                }

                LabeledContent("Ollama") {
                    HStack(spacing: 8) {
                        Text(ollamaStatusText)
                            .foregroundStyle(ollamaReachable == true ? .green : .secondary)
                        Button("Проверить") {
                            Task {
                                await OllamaSidecar.shared.ensureServerRunning()
                                ollamaReachable = await RecapService.shared.probeOllama()
                            }
                        }
                        .controlSize(.small)
                        Button(appState.ollamaSetupProgress != nil ? "Скачиваем…" : "Скачать модель") {
                            appState.startOllamaRuntimeDownload()
                            isInstalling = true
                        }
                        .controlSize(.small)
                        .disabled(appState.ollamaSetupProgress != nil)
                        .onChange(of: appState.ollamaSetupProgress) { _, frac in
                            if frac == nil { isInstalling = false }
                        }
                        .onChange(of: appState.ollamaSetupMessage) { _, msg in
                            if msg == "Модель готова" {
                                ollamaReachable = true
                                isInstalling = false
                            }
                        }
                    }
                }
                if let frac = appState.ollamaSetupProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: frac)
                        Text(appState.ollamaSetupMessage.isEmpty
                             ? "Скачиваем… \(Int(frac * 100))%"
                             : appState.ollamaSetupMessage)
                            .font(.caption)
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
                        }
                    Text("Propeller сам скачивает движок Ollama и модель в Application Support — ставить Ollama.app не нужно.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if recapProvider == RecapProviderKind.openai.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("OpenAI") {
                    SecureField("API-ключ", text: $openAIKey, prompt: Text("sk-…"))
                        .onChange(of: openAIKey) { _, val in
                            Preferences.shared.openAIAPIKey = val
                        }
                    TextField("Модель", text: $recapOpenAIModel, prompt: Text("gpt-4o-mini"))
                        .onChange(of: recapOpenAIModel) { _, val in
                            Preferences.shared.recapOpenAIModel = val
                        }
                    Text("Ключ хранится в Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if recapProvider == RecapProviderKind.claude.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("Claude") {
                    SecureField("API-ключ", text: $claudeKey, prompt: Text("sk-ant-…"))
                        .onChange(of: claudeKey) { _, val in
                            Preferences.shared.claudeAPIKey = val
                        }
                    TextField("Модель", text: $recapClaudeModel, prompt: Text("claude-sonnet-4-5"))
                        .onChange(of: recapClaudeModel) { _, val in
                            Preferences.shared.recapClaudeModel = val
                        }
                    Text("Ключ хранится в Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Промпт") {
                TextEditor(text: $recapPrompt)
                    .font(.callout)
                    .frame(minHeight: 110, maxHeight: 160)
                    .onChange(of: recapPrompt) { _, val in
                        Preferences.shared.recapPrompt = val
                    }
                Button("Сбросить промпт") {
                    recapPrompt = RecapService.defaultPrompt
                    Preferences.shared.recapPrompt = RecapService.defaultPrompt
                }
                .controlSize(.small)
                Text("Если локальная модель ещё не скачана и нет API-ключа, сохранение всё равно работает — саммари пропускается с подсказкой. Кнопка «Скачать модель» ставит движок автоматически.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
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
                    .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Размер библиотеки") {
                let used = ByteCountFormatter.string(
                    fromByteCount: appState.storageLibraryBytes,
                    countStyle: .file
                )
                let limit = ByteCountFormatter.string(
                    fromByteCount: Preferences.shared.storageNudgeThresholdBytes,
                    countStyle: .file
                )
                LabeledContent("Аудио на диске", value: used)
                LabeledContent("Порог напоминания", value: limit)
                Text("Propeller никогда не удаляет сам. При превышении порога — напоминание. Удаление аудио сохраняет расшифровки и саммари.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if Preferences.shared.storageNudgeSnoozed {
                    Button("Сбросить отложку «Позже»") {
                        Preferences.shared.storageNudgeSnoozed = false
                        appState.refreshStorageNudge(presentAlert: true)
                    }
                }
                ForEach(appState.recordingStore.storageNudgeCandidates(limit: 8)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? "Без названия" : entry.title)
                                .lineLimit(1)
                            Text("\(entry.dateFormatted) · \(ByteCountFormatter.string(fromByteCount: appState.recordingStore.byteSize(of: entry), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Удалить аудио") {
                            appState.deleteAudioKeepingMeeting(entry)
                        }
                        .controlSize(.small)
                        Button("Удалить встречу", role: .destructive) {
                            appState.removeRecording(entry)
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
            appState.refreshStorageNudge(presentAlert: false)
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
