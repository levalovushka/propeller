import SwiftUI

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
            SpeakersSettingsPane()
                .tabItem { Label("Speakers", systemImage: "person.2") }
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

    var body: some View {
        Form {
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
            }
        }
        .formStyle(.grouped)
        .onAppear { zoomSnap = ZoomMeetingDetector.shared.probe() }
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
                    .onChange(of: domainTerms) { _, val in Preferences.shared.domainTerms = val }
                Text("Comma-separated vocabulary hints (wired to gigastt hotwords later).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speakers

private struct SpeakersSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("autoMatchThreshold") private var autoMatchThreshold: Double = 0.55
    @AppStorage("recommendThreshold") private var recommendThreshold: Double = 0.30
    @State private var calibration: PeopleStore.CalibrationStats?

    var body: some View {
        Form {
            Section("Matching thresholds") {
                LabeledContent("Auto-match") {
                    HStack {
                        Slider(value: $autoMatchThreshold, in: 0.3...0.9, step: 0.01)
                            .onChange(of: autoMatchThreshold) { _, val in
                                Preferences.shared.autoMatchThreshold = Float(val)
                            }
                        Text(String(format: "%.2f", autoMatchThreshold))
                            .font(.caption.monospaced())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("Cosine similarity required before a diarized voice is auto-labeled with a known person.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Recommend") {
                    HStack {
                        Slider(value: $recommendThreshold, in: 0.1...0.6, step: 0.01)
                            .onChange(of: recommendThreshold) { _, val in
                                Preferences.shared.recommendThreshold = Float(val)
                            }
                        Text(String(format: "%.2f", recommendThreshold))
                            .font(.caption.monospaced())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("Below auto-match: cutoff for suggesting a person as a manual match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calibration") {
                if let c = calibration {
                    calibrationReport(c)
                } else {
                    Button("Analyze library") {
                        calibration = appState.peopleStore.calibrationStats()
                    }
                    Text("Runs cosine similarities over your current People library to suggest a threshold.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func calibrationReport(_ c: PeopleStore.CalibrationStats) -> some View {
        HStack(spacing: 12) {
            distributionStat(label: "Same person", values: c.intra, tint: .green)
            distributionStat(label: "Different people", values: c.inter, tint: .red)
        }
        if let suggestion = c.suggestedThreshold {
            HStack(spacing: 8) {
                Text("Suggested threshold:")
                Text(String(format: "%.2f", suggestion))
                    .font(.body.weight(.semibold).monospaced())
                Button("Apply") {
                    autoMatchThreshold = Double(suggestion)
                    Preferences.shared.autoMatchThreshold = suggestion
                }
                .controlSize(.small)
            }
        } else {
            Text("Need at least one person with ≥2 samples and another person to calibrate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button("Re-analyze") {
            calibration = appState.peopleStore.calibrationStats()
        }
        .controlSize(.small)
    }

    private func distributionStat(label: String, values: [Float], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            if values.isEmpty {
                Text("n/a").font(.caption2).foregroundStyle(.tertiary)
            } else {
                let mean = values.reduce(0, +) / Float(values.count)
                let sorted = values.sorted()
                let minV = sorted.first ?? 0
                let maxV = sorted.last ?? 0
                Text("n=\(values.count)  μ=\(String(format: "%.2f", mean))  [\(String(format: "%.2f", minV))..\(String(format: "%.2f", maxV))]")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Recap (LLM)

private struct RecapSettingsPane: View {
    @AppStorage("recapProvider") private var recapProvider = RecapProviderKind.auto.rawValue
    @AppStorage("recapOllamaModel") private var recapOllamaModel = "llama3.2"
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
                    TextField("Model", text: $recapOllamaModel, prompt: Text("llama3.2"))
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
