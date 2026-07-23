import SwiftUI
import ServiceManagement

/// Native Settings window (⌘,) with talat-style sub-sections, built on the
/// standard macOS settings TabView.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            AudioSettingsPane()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            TranscriptionSettingsPane()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            RecapSettingsPane()
                .tabItem { Label("Recap", systemImage: "sparkles") }
            ExportSettingsPane()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up" ) }
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("zoomAutoRecordMode") private var zoomAutoRecordMode = ZoomAutoRecordMode.auto.rawValue
    @State private var zoomSnap = ZoomMeetingDetector.shared.snapshot
    @State private var hasScreenRecordingPermission = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginError: String?
    @AppStorage("calendarEnabled") private var calendarEnabled = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Propeller at login", isOn: $launchAtLogin)
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
                Text("Propeller starts automatically when you log in, so it's always ready to catch a meeting. macOS manages this under Login Items in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Calendar") {
                Toggle("Show upcoming meetings from Calendar", isOn: $calendarEnabled)
                    .onChange(of: calendarEnabled) { _, on in
                        Preferences.shared.calendarEnabled = on
                        if on {
                            Task { await CalendarService.shared.enableAndLoad() }
                        } else {
                            CalendarService.shared.upcoming = []
                        }
                    }
                Text("Reads your macOS Calendar (including Google/Exchange accounts added in System Settings → Internet Accounts). Nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pipeline") {
                Toggle("Auto-transcribe after recording", isOn: $autoTranscribe)
                    .onChange(of: autoTranscribe) { _, val in Preferences.shared.autoTranscribe = val }
                Text("Transcripts are always saved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Zoom meetings") {
                Picker("When a Zoom call starts", selection: $zoomAutoRecordMode) {
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

                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(zoomProbeLabel(zoomSnap))
                            .foregroundStyle(zoomSnap.inMeeting ? .green : .secondary)
                        Button("Check now") {
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
                            Text("Detection degraded — Screen Recording permission isn't granted, so Propeller can't read Zoom's window title. It falls back to process-only signals, which are slower to catch a call.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Screen Recording Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: LoginItem.appVersionString)
                Text("Update checks arrive with the next release channel.")
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
            return "Zoom is ignored. Start/stop recording manually."
        case .auto:
            return "Recording starts automatically when a Zoom call is detected — no confirmation needed. A notification lets you decline, and you can stop anytime from the menu bar or app. Recording stops when the call ends."
        }
    }

    private func zoomProbeLabel(_ snap: ZoomMeetingSnapshot) -> String {
        if !snap.zoomRunning { return "Zoom: not running" }
        if snap.inMeeting {
            let sig = snap.signals.joined(separator: ", ")
            return "Zoom: in meeting (\(sig))"
        }
        return "Zoom: running, idle"
    }
}

// MARK: - Audio

private struct AudioSettingsPane: View {
    @AppStorage("captureSystemAudio") private var captureSystemAudio = true
    @AppStorage("voiceProcessingEnabled") private var voiceProcessingEnabled = false

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Capture system audio (both sides of calls)", isOn: $captureSystemAudio)
                    .onChange(of: captureSystemAudio) { _, val in Preferences.shared.captureSystemAudio = val }
                Text("Requires Screen Recording permission (macOS will prompt on first recording). When off, only the microphone is captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Cancel speaker echo (for speaker-on meetings)", isOn: $voiceProcessingEnabled)
                    .onChange(of: voiceProcessingEnabled) { _, val in Preferences.shared.voiceProcessingEnabled = val }
                Text("Routes the mic through Apple's voice-processing engine (echo cancellation + noise suppression). Use when you're on a call without headphones. Off by default — has no effect with headphones.")
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
            Section("Engine") {
                LabeledContent("Engine", value: TranscriptionService.engineDescription)
                Text("Speech engine (gigastt) starts automatically with the app. Russian only. First launch may download ~225 MB model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                TextField("Domain terms", text: $domainTerms, prompt: Text("e.g. Газпромнефть, спринт"))
                    .onChange(of: domainTerms) { _, val in
                        Preferences.shared.domainTerms = val
                        scheduleRestart()
                    }
                Text("Comma-separated vocabulary hints — boosted during recognition (brands, names, jargon). Applies to the next transcription; the recognizer restarts a couple seconds after you stop typing.")
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
            restartStatus = "Restarting recognizer to apply vocabulary…"
            Task {
                do {
                    try await GigasttSidecar.shared.restart()
                    await MainActor.run { restartStatus = nil }
                } catch {
                    await MainActor.run { restartStatus = "Recognizer restart failed: \(error.localizedDescription)" }
                }
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - Recap (LLM)

private struct RecapSettingsPane: View {
    @AppStorage("recapProvider") private var recapProvider = RecapProviderKind.auto.rawValue
    @AppStorage("recapOllamaModel") private var recapOllamaModel = "qwen2.5:7b"
    @AppStorage("recapOpenAIModel") private var recapOpenAIModel = "gpt-4o-mini"
    @AppStorage("recapClaudeModel") private var recapClaudeModel = "claude-sonnet-4-5"
    @State private var recapPrompt: String = Preferences.shared.recapPrompt
    @State private var openAIKey: String = Preferences.shared.openAIAPIKey ?? ""
    @State private var claudeKey: String = Preferences.shared.claudeAPIKey ?? ""
    @State private var ollamaReachable: Bool? = nil

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $recapProvider) {
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
                        Button("Check") {
                            Task {
                                ollamaReachable = await RecapService.shared.probeOllama()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            if recapProvider == RecapProviderKind.ollama.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("Ollama") {
                    TextField("Model", text: $recapOllamaModel, prompt: Text("qwen2.5:7b"))
                        .onChange(of: recapOllamaModel) { _, val in
                            Preferences.shared.recapOllamaModel = val
                        }
                }
            }

            if recapProvider == RecapProviderKind.openai.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("OpenAI") {
                    SecureField("API key", text: $openAIKey, prompt: Text("sk-…"))
                        .onChange(of: openAIKey) { _, val in
                            Preferences.shared.openAIAPIKey = val
                        }
                    TextField("Model", text: $recapOpenAIModel, prompt: Text("gpt-4o-mini"))
                        .onChange(of: recapOpenAIModel) { _, val in
                            Preferences.shared.recapOpenAIModel = val
                        }
                    Text("Key is stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if recapProvider == RecapProviderKind.claude.rawValue
                || recapProvider == RecapProviderKind.auto.rawValue {
                Section("Claude") {
                    SecureField("API key", text: $claudeKey, prompt: Text("sk-ant-…"))
                        .onChange(of: claudeKey) { _, val in
                            Preferences.shared.claudeAPIKey = val
                        }
                    TextField("Model", text: $recapClaudeModel, prompt: Text("claude-sonnet-4-5"))
                        .onChange(of: recapClaudeModel) { _, val in
                            Preferences.shared.recapClaudeModel = val
                        }
                    Text("Key is stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Prompt") {
                TextEditor(text: $recapPrompt)
                    .font(.callout)
                    .frame(minHeight: 110, maxHeight: 160)
                    .onChange(of: recapPrompt) { _, val in
                        Preferences.shared.recapPrompt = val
                    }
                Button("Reset prompt to default") {
                    recapPrompt = RecapService.defaultPrompt
                    Preferences.shared.recapPrompt = RecapService.defaultPrompt
                }
                .controlSize(.small)
                Text("If Ollama is down and no API key is set, save still works — recap is skipped with a hint.")
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
        case true: return "reachable on :11434"
        case false: return "not running"
        case nil: return "checking…"
        }
    }
}

// MARK: - Export (output format, storage, retention)

private struct ExportSettingsPane: View {
    @AppStorage("markdownOutputFormat") private var markdownOutputFormat = MarkdownOutputFormat.simple.rawValue
    @AppStorage("meetingsPath") private var meetingsPath = ""
    @AppStorage("recordingsPath") private var recordingsPath = ""
    @AppStorage("peoplePagesPath") private var peoplePagesPath = ""
    @AppStorage("retentionDays") private var retentionDays = 0
    @AppStorage("retentionMode") private var retentionMode = "audio"

    var body: some View {
        Form {
            Section("Markdown format") {
                Picker("Format", selection: $markdownOutputFormat) {
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
                     ? "YAML frontmatter + [[wikilinks]] for Obsidian vault."
                     : "Readable markdown: title, participants, transcript. Default for sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                pathField("Recordings", path: $recordingsPath) {
                    Preferences.shared.recordingsPath = recordingsPath
                }
                pathField("Notes output", path: $meetingsPath) {
                    Preferences.shared.meetingsPath = meetingsPath
                }
                if markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue {
                    pathField("People pages", path: $peoplePagesPath) {
                        Preferences.shared.peoplePagesPath = peoplePagesPath
                    }
                    Text("Obsidian vault folder with people pages. If set, speaker names link to matching pages via [[wikilinks]].")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Auto-delete") {
                Toggle("Auto-delete old recordings", isOn: Binding(
                    get: { retentionDays > 0 },
                    set: { enabled in
                        retentionDays = enabled ? 30 : 0
                        Preferences.shared.retentionDays = retentionDays
                    }
                ))

                if retentionDays > 0 {
                    Picker("Delete after", selection: $retentionDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .onChange(of: retentionDays) { _, val in
                        Preferences.shared.retentionDays = val
                    }

                    Picker("Mode", selection: $retentionMode) {
                        Text("Audio files only").tag("audio")
                        Text("Everything").tag("all")
                    }
                    .onChange(of: retentionMode) { _, val in
                        Preferences.shared.retentionMode = val
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if meetingsPath.isEmpty { meetingsPath = Preferences.shared.meetingsPath }
            if recordingsPath.isEmpty { recordingsPath = Preferences.shared.recordingsPath }
            // peoplePagesPath is intentionally left empty by default (feature off)
        }
    }

    private func pathField(_ label: String, path: Binding<String>, onUpdate: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, text: path)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onChange(of: path.wrappedValue) { _, _ in onUpdate() }
                Button("Browse") {
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
