import Foundation
import TelemetryDeck

/// Thin TelemetryDeck facade for dogfood product signals.
///
/// Never send transcripts, paths, titles, notes, or names — only event names
/// and coarse buckets (`<1m`, `ollama`, `mic_only`, …).
enum Analytics {
    /// TelemetryDeck → Propeller (org `com.propeller`).
    /// Override via Info.plist `TelemetryDeckAppID` / `TELEMETRYDECK_APP_ID` in build.sh.
    private static let appIDConstant = "FD2E1040-C134-4F44-BCAC-76441E1662D7"

    /// Prefer Info.plist `TelemetryDeckAppID`, else the constant above.
    static var appID: String {
        if let plist = Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return appIDConstant
    }

    private static var didBootstrap = false
    /// Kept so opt-out can flip `analyticsDisabled` without re-init (SDK config is a class).
    private static var config: TelemetryDeck.Config?

    /// Call once at process start (`MeetingRecorderApp.init`).
    static func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        let id = appID
        guard !id.isEmpty else {
            NSLog("[Analytics] TelemetryDeck App ID missing — signals disabled. Paste ID in Analytics.swift or set TELEMETRYDECK_APP_ID for build.sh.")
            return
        }
        let config = TelemetryDeck.Config(appID: id)
        config.defaultSignalPrefix = "Propeller."
        config.analyticsDisabled = !Preferences.shared.analyticsEnabled
        self.config = config
        TelemetryDeck.initialize(config: config)
        NSLog("[Analytics] TelemetryDeck ready (enabled=\(Preferences.shared.analyticsEnabled))")
        signal("App.opened")
    }

    static func setEnabled(_ enabled: Bool) {
        Preferences.shared.analyticsEnabled = enabled
        config?.analyticsDisabled = !enabled
        if enabled {
            signal("Analytics.enabled")
        }
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard Preferences.shared.analyticsEnabled, !appID.isEmpty, config != nil else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    // MARK: - Funnel helpers (no content)

    static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "<1m"
        case ..<900: return "1-15m"
        case ..<3600: return "15-60m"
        default: return "60m+"
        }
    }

    static func recordingStarted(source: String) {
        signal("Recording.started", parameters: ["source": source])
    }

    static func recordingFinished(duration: TimeInterval, micOnly: Bool) {
        signal("Recording.finished", parameters: [
            "duration": durationBucket(duration),
            "audio": micOnly ? "mic_only" : "mic_plus_system",
        ])
    }

    static func recordingCancelled() {
        signal("Recording.cancelled")
    }

    static func transcriptionFinished(ok: Bool, reason: String? = nil) {
        var params = ["result": ok ? "ok" : "fail"]
        if let reason, !reason.isEmpty {
            params["reason"] = String(reason.prefix(40))
        }
        signal("Transcription.finished", parameters: params)
    }

    static func recapFinished(ok: Bool, backend: String? = nil, skip: String? = nil) {
        var params: [String: String]
        if ok {
            params = ["result": "ok"]
        } else if skip != nil {
            params = ["result": "skip"]
        } else {
            params = ["result": "fail"]
        }
        if let backend { params["backend"] = backend }
        if let skip { params["skip"] = skip }
        signal("Recap.finished", parameters: params)
    }
}
