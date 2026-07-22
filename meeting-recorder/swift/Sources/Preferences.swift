import AppKit
import Foundation

class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - Transcription

    var domainTerms: String {
        get { defaults.string(forKey: "domainTerms") ?? "" }
        set { defaults.set(newValue, forKey: "domainTerms") }
    }

    // MARK: - Automation

    var autoTranscribe: Bool {
        get { defaults.object(forKey: "autoTranscribe") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoTranscribe") }
    }

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

    // MARK: - Speaker matching thresholds

    /// Cosine similarity required to auto-match a diarized speaker to a known
    /// person. Default tuned for max-over-samples matching.
    var autoMatchThreshold: Float {
        get {
            let v = defaults.double(forKey: "autoMatchThreshold")
            return v > 0 ? Float(v) : Float(PeopleStore.defaultAutoMatchThreshold)
        }
        set { defaults.set(Double(newValue), forKey: "autoMatchThreshold") }
    }

    /// Minimum cosine to show a person as a recommendation (below auto).
    var recommendThreshold: Float {
        get {
            let v = defaults.double(forKey: "recommendThreshold")
            return v > 0 ? Float(v) : 0.30
        }
        set { defaults.set(Double(newValue), forKey: "recommendThreshold") }
    }

    // MARK: - Global Hotkey

    /// Hardware key code for the global toggle-recording hotkey (default: 15 = 'R').
    var hotkeyKeyCode: UInt16 {
        get {
            let v = defaults.integer(forKey: "hotkeyKeyCode")
            return v > 0 ? UInt16(v) : 15
        }
        set { defaults.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    /// Raw modifier flags for the global hotkey (default: Ctrl + Opt).
    var hotkeyModifiers: UInt {
        get {
            let v = defaults.object(forKey: "hotkeyModifiers") as? UInt
            return v ?? (NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.option.rawValue)
        }
        set { defaults.set(newValue, forKey: "hotkeyModifiers") }
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
            return stored.isEmpty ? RecapService.defaultPrompt : stored
        }
        set { defaults.set(newValue, forKey: "recapPrompt") }
    }

    var recapOllamaModel: String {
        get {
            let v = defaults.string(forKey: "recapOllamaModel") ?? ""
            return v.isEmpty ? "llama3.2" : v
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

    // MARK: - Retention

    var retentionEnabled: Bool {
        get { retentionDays > 0 }
        set { retentionDays = newValue ? 30 : 0 }
    }

    var retentionDays: Int {
        get { defaults.integer(forKey: "retentionDays") }
        set { defaults.set(newValue, forKey: "retentionDays") }
    }

    var retentionMode: String {
        get { defaults.string(forKey: "retentionMode") ?? "audio" }
        set { defaults.set(newValue, forKey: "retentionMode") }
    }

    // MARK: - Onboarding

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }

    /// The name the user entered during onboarding (used to pre-create their Person).
    var userName: String {
        get { defaults.string(forKey: "userName") ?? "" }
        set { defaults.set(newValue, forKey: "userName") }
    }

    // MARK: - Defaults

    static let basePath = NSHomeDirectory() + "/.meeting-recorder"
    private var defaultMeetingsPath: String { Self.basePath + "/meetings" }
    private var defaultRecordingsPath: String { Self.basePath + "/recordings" }
    static var peoplePath: String { basePath + "/people" }

    // Legacy path for migration
    static var legacyVoicesPath: String { basePath + "/voices" }
}
