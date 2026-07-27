import Foundation

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

    /// Capture system audio output (other participants in video calls) alongside the mic.
    /// Requires Screen Recording permission. On first use macOS will prompt.
    var captureSystemAudio: Bool {
        get { defaults.object(forKey: "captureSystemAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captureSystemAudio") }
    }

    /// Run the microphone input through Apple's Voice Processing AU
    /// (acoustic echo cancellation + noise suppression). Recommended when
    /// the user is on speaker — the remote participants' voices coming back
    /// through the mic are subtracted, so the mic stem contains only the
    /// in-room speaker(s). Diarization then sees a clean source-aware split
    /// between mic (you) and the system stem (everyone else).
    var voiceProcessingEnabled: Bool {
        get { defaults.object(forKey: "voiceProcessingEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "voiceProcessingEnabled") }
    }

    /// Zoom meeting auto-record: off / auto. Default auto: recording starts
    /// automatically and a notification lets the user decline.
    var zoomAutoRecordMode: ZoomAutoRecordMode {
        get {
            let raw = defaults.string(forKey: "zoomAutoRecordMode") ?? ""
            // Migrate the removed "ask" mode to auto (no confirmation prompt).
            if raw == "ask" { return .auto }
            return ZoomAutoRecordMode(rawValue: raw) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: "zoomAutoRecordMode") }
    }

    // MARK: - Paths

    var meetingsPath: String {
        get { defaults.string(forKey: "meetingsPath") ?? defaultMeetingsPath }
        set { defaults.set(newValue, forKey: "meetingsPath") }
    }

    var recordingsPath: String {
        get { defaults.string(forKey: "recordingsPath") ?? defaultRecordingsPath }
        set { defaults.set(newValue, forKey: "recordingsPath") }
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
            RecapProviderKind(rawValue: defaults.string(forKey: "recapProvider") ?? "") ?? .auto
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

    var recapOllamaModel: String {
        get {
            let v = defaults.string(forKey: "recapOllamaModel") ?? ""
            return v.isEmpty ? "qwen2.5:7b" : v
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

    // MARK: - Storage nudge (plan-v2 6.1 — never auto-deletes)

    /// Soft library-size threshold. Default 5 GB (DECIDE-4).
    var storageNudgeThresholdBytes: Int64 {
        get {
            let v = defaults.object(forKey: "storageNudgeThresholdBytes") as? Int64
            return v ?? (5 * 1024 * 1024 * 1024)
        }
        set { defaults.set(newValue, forKey: "storageNudgeThresholdBytes") }
    }

    /// User tapped "Later" — don't re-alert until they clear the snooze (Settings) or shrink below threshold.
    var storageNudgeSnoozed: Bool {
        get { defaults.bool(forKey: "storageNudgeSnoozed") }
        set { defaults.set(newValue, forKey: "storageNudgeSnoozed") }
    }

    // MARK: - Analytics (TelemetryDeck)

    /// Product signals for dogfood iteration. Default on; Settings can opt out.
    /// Never includes transcripts, paths, titles, or free text.
    var analyticsEnabled: Bool {
        get { defaults.object(forKey: "analyticsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "analyticsEnabled") }
    }

    // MARK: - Onboarding

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }

    /// The name the user entered during onboarding — used to label the
    /// mic-dominant diarized speaker with their real name (see plan-v2 3.3).
    var userName: String {
        get { defaults.string(forKey: "userName") ?? "" }
        set { defaults.set(newValue, forKey: "userName") }
    }

    /// Show upcoming meetings from the system Calendar (EventKit). Off until the
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
