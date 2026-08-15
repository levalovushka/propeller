import Foundation
import PropellerPure
import TelemetryDeck

/// Thin TelemetryDeck facade for dogfood product signals.
///
/// Never send transcripts, paths, titles, notes, or names — only event names
/// and coarse buckets (`<1m`, `ollama`, `mic_only`, …).
enum Analytics {
    /// TelemetryDeck → Propeller (org `com.propeller`).
    /// Always baked into release builds via `build.sh` (Info.plist + this constant).
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
            NSLog("[Analytics] TelemetryDeck App ID missing — signals disabled.")
            return
        }
        let config = TelemetryDeck.Config(appID: id)
        config.defaultSignalPrefix = "Propeller."
        config.analyticsDisabled = !Preferences.shared.analyticsEnabled
        // Every signal — including the SDK's own session ones — carries the
        // configuration it happened under. Without this, "у кого именно ломается"
        // needs a new parameter at every call site; with it, the question is a
        // filter on data already collected.
        config.defaultParameters = { Analytics.environment() }
        // Dogfood DMGs are always `-c release`, but be explicit so Live Mode
        // insights aren't empty because someone glanced at Test Mode only.
        #if DEBUG
        config.testMode = true
        #else
        config.testMode = false
        #endif
        // Surface send status in Console (subsystem TelemetryDeck / Analytics).
        config.logHandler = .standard(.info)
        self.config = config
        TelemetryDeck.initialize(config: config)
        // The session the SDK just opened belongs to today; the next one is owed
        // when the day turns over (see `noteDayBoundary`).
        lastSessionDay = today()
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        NSLog("[Analytics] TelemetryDeck ready (enabled=\(Preferences.shared.analyticsEnabled) testMode=\(config.testMode) app=\(ver) id=\(id.prefix(8))…)")
        signal("App.opened", parameters: [
            "version": ver,
            "test_mode": config.testMode ? "1" : "0",
        ])
        // Всё, что Клод наспрашивал, пока приложение было закрыто.
        reportClaudeUsage()
        // Menu-bar apps often quit before the default 10s batch timer — push once.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            TelemetryDeck.requestImmediateSync()
        }
    }

    /// Flush pending signals (call on quit). Best-effort.
    static func flush() {
        guard Preferences.shared.analyticsEnabled, config != nil else { return }
        TelemetryDeck.requestImmediateSync()
    }

    static func setEnabled(_ enabled: Bool) {
        Preferences.shared.analyticsEnabled = enabled
        config?.analyticsDisabled = !enabled
        if enabled {
            signal("Analytics.enabled")
            flush()
        }
    }

    static func signal(_ name: String, parameters: [String: String] = [:], value: Double? = nil) {
        guard Preferences.shared.analyticsEnabled, !appID.isEmpty, config != nil else { return }
        TelemetryDeck.signal(name, parameters: parameters, floatValue: value)
    }

    // MARK: - Environment

    /// Coarse configuration attached to every signal.
    ///
    /// Read on the SDK's own queue, so it may touch `UserDefaults` and nothing
    /// else — no AppState, no disk, no window. Never anything a person typed:
    /// no names, paths, titles or model keys. Hardware, OS, locale and appearance
    /// already arrive from the SDK, so they are not repeated here.
    private static func environment() -> [String: String] {
        let prefs = Preferences.shared
        return [
            "auto_record": prefs.autoRecordMode.rawValue,
            "recap_provider": prefs.recapProvider.rawValue,
            "markdown": prefs.markdownOutputFormat.rawValue,
            "calendar": prefs.calendarEnabled ? "on" : "off",
            "onboarded": prefs.onboardingCompleted ? "1" : "0",
            // nil means "never measured yet", which is a third answer, not a no.
            "capture_path": prefs.sharedClockCaptureWorks.map { $0 ? "shared_clock" : "mic_only" } ?? "unknown",
        ]
    }

    // MARK: - Sessions

    /// ISO day (`2026-08-11`) of the session currently open.
    private static var lastSessionDay: String? {
        get { UserDefaults.standard.string(forKey: "analyticsSessionDay") }
        set { UserDefaults.standard.set(newValue, forKey: "analyticsSessionDay") }
    }

    private static func today() -> String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
    }

    /// Roll the session over when the calendar day turns.
    ///
    /// The SDK opens a session when the *process* starts (`Config.sessionID`
    /// didSet) — for a menu-bar app that runs for weeks that is one session per
    /// install, and every "how many days was it alive" question reads as one day.
    /// Called from the wake and activation observers, so a laptop that sleeps
    /// through the night reports the new day when it opens.
    ///
    /// Note this does *not* repair `TelemetryDeck.Retention.distinctDaysUsed`:
    /// the SDK refreshes that counter only in `SessionManager.init`, i.e. on
    /// process start. Count active days from the signals, not from that field.
    static func noteDayBoundary() {
        guard Preferences.shared.analyticsEnabled, config != nil else { return }
        let day = today()
        guard lastSessionDay != day else { return }
        lastSessionDay = day
        TelemetryDeck.generateNewSession()
        // День перевалил — самое время отдать накопленное: приложение из меню
        // бара живёт неделями, и ждать его перезапуска значило бы не увидеть
        // использования вовсе.
        reportClaudeUsage()
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

    /// Coarse age of a recording at the moment it was thrown away. The first
    /// bucket is the one that matters: an auto-started recording killed inside
    /// ten seconds is a wrong call detection, not a change of mind.
    static func ageBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: return "<10s"
        case ..<60: return "10-60s"
        case ..<300: return "1-5m"
        default: return "5m+"
        }
    }

    /// «Не записывать». `source` is how the recording began (`auto` / `manual`),
    /// `age` how long it had been running — together they separate a false
    /// auto-start from a person who decided against the meeting they started.
    /// Field answer to the acceptance criterion in STATE.md §8.
    static func recordingCancelled(source: String, age: TimeInterval?) {
        var params = ["source": source]
        if let age { params["age"] = ageBucket(age) }
        signal("Recording.cancelled", parameters: params, value: age)
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

    /// Как прошла локальная генерация конспекта — оси со стенда, чтобы прод и
    /// стендовые таблицы читались одной головой (RELEASE-1.16.5.md, Г5): длина
    /// ответа в токенах, был ли повтор и схлопнулся ли итог, сколько пунктов
    /// уехало читателю, версия конструкции, когорта памяти. Длительность — в
    /// `value`. Только числа и флаги, ни слова из встречи.
    ///
    /// Это же — линейка отката после релиза: доля `collapsed` и время генерации
    /// в проде против стендовых. Облачные бэкенды сигнал не шлют: их
    /// конструкция в 1.16.5 не менялась, и длину ответа они не сообщают.
    ///
    /// `author` — кто написал документ переполняющей встречи: свод модели или
    /// механическая сборка, отобравшая его гвардом (`RecapDigestGuard`). Только
    /// у пути нарезки: на одиночном выбирать не из чего. Доля `assembly` — это и
    /// есть частота срыва свода в проде, то самое число, ради которого страховку
    /// оставили видимой.
    static func recapGenerated(
        replyTokens: Int?,
        retried: Bool,
        collapsed: Bool,
        seconds: Double,
        bullets: Int,
        chunked: Bool,
        version: Int,
        author: RecapDigestGuard.Author? = nil
    ) {
        var params = [
            "retried": retried ? "1" : "0",
            "collapsed": collapsed ? "1" : "0",
            "bullets": String(bullets),
            "chunked": chunked ? "1" : "0",
            "generator": String(version),
            "ram": RecapGenerationPolicy.ramCohort(bytes: ProcessInfo.processInfo.physicalMemory),
        ]
        if let replyTokens { params["reply_tokens"] = String(replyTokens) }
        if let author { params["author"] = author.rawValue }
        signal("Recap.generated", parameters: params, value: seconds)
    }

    // MARK: - Claude

    /// Сколько раз человек на самом деле спросил Клода о встречах.
    ///
    /// Единственный сигнал, который отвечает на вопрос «пользуются ли фичей».
    /// `Claude.connected` говорит, что кнопку нажали; отметка — что Клод поднял
    /// наш процесс, а он поднимает его на своём старте, у всех подключивших,
    /// каждый день. Ни то ни другое не про использование.
    ///
    /// Вызовы считает сервер (`ClaudeUsage`), потому что случаются они в его
    /// процессе; отправляем их отсюда, чтобы у того процесса не заводилось ни
    /// сети, ни SDK, ни очереди. Читается журнал **переименованием**: сервер в
    /// это время может дописывать, и подмена имени — единственный способ забрать
    /// накопленное, ничего не потеряв между чтением и стиранием.
    ///
    /// В сигнале нет ни одной строки из архива: имя инструмента и число.
    static func reportClaudeUsage() {
        let manager = FileManager.default
        let log = ClaudeConnector.usageLogURL
        guard manager.fileExists(atPath: log.path) else { return }
        let taken = log.deletingLastPathComponent()
            .appendingPathComponent(ClaudeUsage.logFileName + ".taken")
        try? manager.removeItem(at: taken)
        do {
            try manager.moveItem(at: log, to: taken)
        } catch {
            return
        }
        defer { try? manager.removeItem(at: taken) }

        guard let text = try? String(contentsOf: taken, encoding: .utf8) else { return }
        let summary = ClaudeUsage.summarize(text)
        guard !summary.isEmpty else { return }

        for (tool, count) in summary.calls.sorted(by: { $0.key < $1.key }) {
            signal("Claude.used", parameters: [
                "tool": tool,
                "frequency": ClaudeUsage.frequencyBucket(count),
                "days": String(summary.activeDays),
            ], value: Double(count))
        }
    }

    /// How long the person waited between the meeting ending and the summary
    /// existing — the promise the product actually makes, and the one number
    /// none of the phase signals contained.
    ///
    /// Sent as its own signal rather than a `floatValue` on `Recap.finished`,
    /// because failures and skips have no wait to report and would drag the
    /// average toward zero. `awaited` separates the meeting somebody is sitting
    /// in front of from the backlog a launch is catching up on; only the first
    /// one is a wait a person felt.
    static func summaryWaited(seconds: TimeInterval, awaited: Bool, meetingDuration: TimeInterval) {
        guard seconds > 0 else { return }
        signal(
            "Summary.waited",
            parameters: [
                "awaited": awaited ? "1" : "0",
                "meeting": durationBucket(meetingDuration),
            ],
            value: seconds
        )
    }
}
