import Foundation

/// Whether a failure is worth trying again on its own.
///
/// This is the whole difference between "the app quietly caught up" and "the
/// user found a red button in their archive three days later". A missing model,
/// a sidecar that had not finished starting, a laptop that went to sleep
/// mid-summary — all of those fix themselves, and the recording should be
/// picked back up without anyone being told about it. A deleted audio file or
/// an empty transcript never fixes itself, and pretending otherwise burns CPU
/// on a loop the user cannot see.
public enum FailureKind: String, Codable, Sendable {
    /// The world was briefly wrong. Retried on a backoff, silently.
    case transient
    /// Nothing changes without the user. Parked, and *shown*.
    case permanent
}

/// How often the worker tries again, and how it decides whether to.
///
/// Deliberately without jitter. Jitter exists to desynchronise many clients
/// hitting one server (AWS, "Exponential Backoff and Jitter"); here there is
/// one client and a server on loopback, so randomness would only make the
/// behaviour untestable.
public enum PipelineRetry {

    /// Backoff between attempts: 20 s, 1 min, 5 min, 20 min.
    ///
    /// The first step is short because the overwhelming majority of real
    /// failures here are "not up yet" — `ollama serve` still loading, the ASR
    /// sidecar mid-spawn, a model being written to disk. The tail is long
    /// because anything that survives four attempts is an environment problem,
    /// and hammering it costs battery for nothing.
    public static let steps: [TimeInterval] = [20, 60, 300, 1200]

    /// Total attempts a phase gets, first one included.
    ///
    /// ASR gets fewer than the summary on purpose: re-running it can mean
    /// minutes of CPU on a long meeting, while its cheap failure mode (sidecar
    /// not listening) shows up in the first second. A summary is the phase that
    /// waits on a model download or a rate limit, so it is the one that
    /// benefits from a long, patient tail.
    public static func maxAttempts(for phase: PipelineActivity.Phase) -> Int {
        switch phase {
        case .transcribing, .diarizing: return 3
        case .saving:                   return 3
        case .summarizing:              return 5
        }
    }

    /// When the worker may try this phase again by itself, or nil when it may
    /// not — either the failure is permanent or the attempts are spent.
    public static func nextAttempt(
        kind: FailureKind,
        attempt: Int,
        phase: PipelineActivity.Phase,
        after now: Date
    ) -> Date? {
        guard kind == .transient else { return nil }
        guard attempt >= 1, attempt < maxAttempts(for: phase) else { return nil }
        return now.addingTimeInterval(steps[min(attempt - 1, steps.count - 1)])
    }

    /// How long to wait before asking again whether a summary provider showed
    /// up, given how many drains in a row have ended blocked on it.
    ///
    /// The question itself is cheap — a file check, or one request to a server
    /// that is already running — but a user who has decided not to install a
    /// model should not pay for it every minute forever, so the interval walks
    /// out to half an hour and stays there.
    public static func providerRecheck(afterBlockedStreak streak: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [60, 300, 900, 1800]
        return ladder[min(max(streak, 1) - 1, ladder.count - 1)]
    }

    // MARK: - Classification

    /// Read a failure message and decide whether waiting could help.
    ///
    /// Text matching, because that is what the pipeline actually has: most of
    /// these errors arrive as `localizedDescription` from a sidecar, URLSession
    /// or Foundation. Call sites that know better pass the kind explicitly.
    ///
    /// Permanent patterns are checked first: "gigastt недоступен — файл не
    /// найден" must not be read as a transport problem.
    public static func classify(_ message: String) -> FailureKind {
        let text = message.lowercased()
        for marker in permanentMarkers where text.contains(marker) { return .permanent }
        for marker in transientMarkers where text.contains(marker) { return .transient }
        // Unknown errors are treated as transient: the common unknown on this
        // pipeline is an environment hiccup, and `maxAttempts` bounds the cost
        // of being wrong at two extra tries.
        return .transient
    }

    /// Data, not code, so a new case is one string and one test.
    static let permanentMarkers: [String] = [
        // The input is gone or unusable.
        "не найден", "не найдено", "not found", "no such file", "нет аудио",
        "нет транскрипта", "пуст", "empty", "0 байт",
        // The request can never fit as built (client chunking bug, not weather).
        "413", "too large", "слишком велик", "слишком больш",
        // Needs a person: disk, permissions, settings.
        "мало места", "недостаточно места", "no space", "disk full",
        "permission", "denied", "разрешени", "доступ запрещ",
        // A reasoning model that spent the whole window thinking will spend it
        // again on the next identical call.
        "ушла в рассуждения",
    ]

    static let transientMarkers: [String] = [
        "недоступен", "unavailable", "не запущен", "not running",
        "timed out", "timeout", "таймаут", "не успело", "перегружен",
        "connection", "соединени", "network", "сеть", "offline", "офлайн",
        "socket", "broken pipe", "eof", "cannot connect", "could not connect",
        "не удалось подключиться", "temporarily", "busy", "занят",
        "408", "429", "500", "502", "503", "504",
    ]
}
