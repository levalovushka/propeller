import Foundation
import PropellerMetrics
import PropellerPure

enum RecapProviderKind: String, CaseIterable, Identifiable {
    case auto
    case ollama
    case openai
    case claude
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Авто"
        case .ollama: return "Ollama"
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .off: return "Выкл"
        }
    }
}

enum RecapSkipReason: Error, Equatable {
    case disabled
    case noProvider
    case emptyTranscript
}

enum RecapError: LocalizedError {
    case httpStatus(Int, String)
    case emptyResponse
    case badJSON
    case providerUnavailable(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return "LLM HTTP \(code): \(body.prefix(200))"
        case .emptyResponse:
            return "LLM вернул пустое саммари"
        case .badJSON:
            return "Не удалось разобрать ответ LLM"
        case .providerUnavailable(let name):
            return "\(name) недоступен"
        case .timedOut:
            return "Саммари не успело за 10 минут — модель перегружена. Подожди минуту и нажми «Сгенерировать» снова."
        }
    }
}

struct RecapResult {
    let path: String
    let provider: String
    let body: String
}

/// LLM meeting recap on top of a saved transcript markdown.
actor RecapService {
    static let shared = RecapService()

    static let defaultPrompt = """
    Ты — эксперт по ведению конспектов встреч. На основе транскрипта ниже составь конспект, по которому человек, не присутствовавший на встрече, точно поймёт, о чём договорились.

    ГЛАВНЫЙ ПРИНЦИП
    Конспект — это договорённости и решения, а не стенограмма. Отделяй суть от хаоса разговора: чистые решения и задачи выноси вперёд, ход обсуждения оставляй ниже как справочный слой. Не пересказывай всё подряд — фиксируй то, что меняет положение дел: что решили, кто что делает, что осталось открытым.

    ЗАМЕТКИ ПОЛЬЗОВАТЕЛЯ
    Если пользователь приложил свои заметки со встречи — это маркер того, что он счёл важным. Вплетай их в конспект по смыслу, а не отдельным списком.

    СТИЛЬ (информационный стиль)
    - Активный залог, конкретные формулировки. «Пётр готовит смету к пятнице», а не «было решено, что смета будет подготовлена».
    - Без канцелярита, вводных оборотов и воды. Каждая строка несёт факт или договорённость.
    - Формулировки проверяемы: по ним видно, выполнено или нет.
    - Слова участников используй там, где важна точная формулировка (спорные места, обещания, цифры).

    СТРУКТУРА (Markdown, заголовки через ##, никогда #; жирный ** и списки -)

    ## Итог
    2–3 предложения: зачем собирались и к чему пришли. Результат, а не повестка.

    ## Решения
    - Что решили. Каждый пункт — завершённая договорённость.

    ## Задачи
    - **Кто** — что делает — **к какому сроку**. Ответственного и срок указывай, если они есть в транскрипте; если не названы — не выдумывай, пиши задачу без них.

    ## Открытые вопросы
    - Что обсудили, но не решили; что заблокировано и чего ждёт.

    ## Ход обсуждения
    Хронологический разбор по темам, каждая с таймкодом начала (например: «- [00:04:32] Ревью онбординга»). Здесь — контекст, аргументы, детали, которые не попали выше. Это справочный слой; не дублируй сюда решения и задачи целиком.

    ## Прочее
    Всё остальное, что стоит зафиксировать.

    ПРАВИЛА
    - Не выдумывай того, чего нет в транскрипте.
    - Пустые секции полностью опускай — не пиши «Нет» или «—».
    - Детальность — в служении понятности, а не подробности ради подробности.
    - Не добавляй шапку Date / Duration / Participants (и аналоги) — дата, длительность и участники уже есть в UI встречи.
    - Блок «Заметки» в итоговый файл добавит система отдельно — не дублируй сырые заметки отдельной секцией; их смысл уже вплетён выше.
    - По контексту аккуратно исправляй очевидные ASR-ошибки (искажённые имена и термины), не меняя смысл.
    """

    /// Always appended so a custom Settings prompt can't drop the language lock
    /// (Qwen and similar models occasionally leak Chinese otherwise).
    private static let languageLock = """

    ЯЗЫК ОТВЕТА (жёстко): только русский. Никакого китайского и других языков, кроме имён и устоявшихся латиницей терминов.
    """

    /// Local qwen can sit silent for minutes (cold load ~4–5 GB + generate) with
    /// `stream: false` — URLSession's request timeout is idle-until-first-byte, so
    /// 180s was aborting real meetings with "The request timed out."
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    // MARK: - Public

    func probeOllama(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.timeoutInterval = 5   // Ollama can be slow to answer the first request after wake/launch
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Resolve which backend to use given preferences. Returns nil + reason if skipped.
    func resolveBackend(
        kind: RecapProviderKind,
        openAIKey: String?,
        claudeKey: String?
    ) async -> Result<String, RecapSkipReason> {
        switch kind {
        case .off:
            return .failure(.disabled)
        case .ollama:
            await OllamaSidecar.shared.ensureServerRunning()
            return await probeOllama() ? .success("ollama") : .failure(.noProvider)
        case .openai:
            return (openAIKey?.isEmpty == false) ? .success("openai") : .failure(.noProvider)
        case .claude:
            return (claudeKey?.isEmpty == false) ? .success("claude") : .failure(.noProvider)
        case .auto:
            await OllamaSidecar.shared.ensureServerRunning()
            if await probeOllama() { return .success("ollama") }
            if openAIKey?.isEmpty == false { return .success("openai") }
            if claudeKey?.isEmpty == false { return .success("claude") }
            return .failure(.noProvider)
        }
    }

    func generateRecap(
        title: String,
        transcriptMarkdown: String,
        transcriptPath: String,
        notes: String?,
        speakers: [String],
        duration: TimeInterval,
        recordingID: String,
        prefs: RecapPreferences
    ) async throws -> Result<RecapResult, RecapSkipReason> {
        try await PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.recap) {
            let trimmed = transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyTranscript) }

            let backend: String
            switch await resolveBackend(kind: prefs.provider, openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey) {
            case .failure(let reason):
                return .failure(reason)
            case .success(let name):
                backend = name
            }

            let prompt = (prefs.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultPrompt
                : prefs.prompt) + Self.languageLock

            let userContent = buildUserMessage(
                title: title,
                transcriptMarkdown: trimmed,
                speakers: speakers,
                duration: duration,
                notes: notes
            )

            let raw: String
            switch backend {
            case "ollama":
                raw = try await callOllama(model: prefs.ollamaModel, system: prompt, user: userContent)
            case "openai":
                raw = try await callOpenAI(apiKey: prefs.openAIKey ?? "", model: prefs.openAIModel, system: prompt, user: userContent)
            case "claude":
                raw = try await callClaude(apiKey: prefs.claudeKey ?? "", model: prefs.claudeModel, system: prompt, user: userContent)
            default:
                return .failure(.noProvider)
            }

            let cleaned = RecapMetadataParser.stripCodeFences(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw RecapError.emptyResponse }

            let body = wrapRecapDocument(
                title: title,
                recapBody: cleaned,
                notes: notes,
                speakers: speakers,
                duration: duration,
                format: prefs.outputFormat
            )

            let path = try writeRecapFile(
                nextToTranscriptPath: transcriptPath,
                recordingID: recordingID,
                title: title,
                content: body
            )

            return .success(RecapResult(path: path, provider: backend, body: body))
        }
    }

    // MARK: - Meeting metadata (title / topics / tags) from the finished summary

    struct RecapMetadata {
        /// nil when the title should not change (manual title, or model returned null).
        let title: String?
        let topics: [String]
        let tags: [String]
    }

    /// Derive a short title, subtitle topics, and vocabulary tags from the finished
    /// summary. Runs on the small summary (not the full transcript) as a separate
    /// structured JSON call, so the readable recap stays untouched and parsing stays
    /// robust. Best-effort: returns nil on any provider/parse failure (feature degrades).
    func generateMetadata(
        summaryMarkdown: String,
        needTitle: Bool,
        prefs: RecapPreferences
    ) async -> RecapMetadata? {
        let trimmed = summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let backend: String
        switch await resolveBackend(kind: prefs.provider, openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey) {
        case .failure: return nil
        case .success(let name): backend = name
        }

        let system = Self.metadataPrompt(needTitle: needTitle)
        let user = "Саммари встречи:\n\n\(trimmed)"

        let raw: String
        do {
            switch backend {
            case "ollama": raw = try await callOllama(model: prefs.ollamaModel, system: system, user: user)
            case "openai": raw = try await callOpenAI(apiKey: prefs.openAIKey ?? "", model: prefs.openAIModel, system: system, user: user)
            case "claude": raw = try await callClaude(apiKey: prefs.claudeKey ?? "", model: prefs.claudeModel, system: system, user: user)
            default: return nil
            }
        } catch {
            NSLog("[RecapService] metadata generation failed: \(error)")
            return nil
        }

        guard let parsed = RecapMetadataParser.parse(
            RecapMetadataParser.stripCodeFences(raw),
            allowedTags: Set(MeetingTags.vocabulary)
        ) else { return nil }
        return RecapMetadata(title: parsed.title, topics: parsed.topics, tags: parsed.tags)
    }

    private static func metadataPrompt(needTitle: Bool) -> String {
        let vocab = MeetingTags.vocabulary.joined(separator: ", ")
        return """
        Ты анализируешь готовое саммари рабочей встречи и возвращаешь СТРОГО один JSON-объект без пояснений и без markdown-ограждений.
        Формат: {"title": <строка или null>, "topics": [<строка>, ...], "tags": [<строка>, ...]}
        Правила:
        - title: суть встречи одной ёмкой фразой на русском, 3–7 слов.\(needTitle ? "" : " Заголовок уже задан пользователем — верни null.")
        - topics: 2–5 ключевых обсуждённых тем короткими фразами на русском (пойдут в сабтайтл). Только то, что реально есть в саммари, не выдумывай. Без китайского и других языков.
        - tags: 0..N значений СТРОГО из списка: [\(vocab)]. Значения вне списка запрещены. Если ничего не подходит — пустой массив [].
        - Верни только JSON, никакого текста вокруг. Все строковые значения — на русском.
        """
    }

    // MARK: - Prompt assembly

    private func buildUserMessage(
        title: String,
        transcriptMarkdown: String,
        speakers: [String],
        duration: TimeInterval,
        notes: String?
    ) -> String {
        _ = speakers
        _ = duration
        var parts: [String] = []
        parts.append("Встреча: \(title.isEmpty ? "без названия" : title)")
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedNotes.isEmpty {
            parts.append("")
            parts.append("Заметки пользователя (якоря — приоритетнее болтовни в транскрипте):")
            parts.append(trimmedNotes)
        }
        parts.append("")
        parts.append("Транскрипт:")
        parts.append(transcriptMarkdown)
        parts.append("")
        parts.append("Ответь строго на русском языке.")
        return parts.joined(separator: "\n")
    }

    private func wrapRecapDocument(
        title: String,
        recapBody: String,
        notes: String?,
        speakers: [String],
        duration: TimeInterval,
        format: MarkdownOutputFormat
    ) -> String {
        _ = speakers
        _ = duration
        let heading = title.isEmpty ? "Meeting recap" : "\(title) — рекап"

        var lines: [String] = []
        switch format {
        case .simple:
            lines.append("# \(heading)")
            lines.append("")
            lines.append(recapBody)
        case .obsidian:
            let safeTitle = heading.replacingOccurrences(of: "\"", with: "'")
            lines.append("---")
            lines.append("title: \"\(safeTitle)\"")
            lines.append("tags: [meeting, recap]")
            lines.append("---")
            lines.append("")
            lines.append(recapBody)
        }

        // Notes stay verbatim — never rewritten by the LLM.
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## Заметки")
            lines.append("")
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func writeRecapFile(
        nextToTranscriptPath: String,
        recordingID: String,
        title: String,
        content: String
    ) throws -> String {
        let transcriptURL = URL(fileURLWithPath: nextToTranscriptPath)
        let dir = transcriptURL.deletingLastPathComponent()
        let slug = MarkdownWriter.slugify(title.isEmpty ? recordingID : title)
        let filename = "\(recordingID)-\(slug)-recap.md"
        let filepath = dir.appendingPathComponent(filename)

        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let prefix = recordingID + "-"
            for file in contents where file.pathExtension == "md"
                && file.lastPathComponent.hasPrefix(prefix)
                && file.lastPathComponent.hasSuffix("-recap.md")
                && file.lastPathComponent != filename {
                try? fm.removeItem(at: file)
            }
        }

        try content.write(to: filepath, atomically: true, encoding: .utf8)
        return filepath.path
    }

    // MARK: - Providers

    private func callOllama(model: String, system: String, user: String) async throws -> String {
        let url = URL(string: "http://127.0.0.1:11434/api/chat")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Whole wall-clock budget: cold load + long transcript. Must match session.
        req.timeoutInterval = 600

        // Without an explicit num_ctx Ollama runs a ~4k sliding window and drops
        // the *oldest* tokens, so the recap silently describes only the tail of
        // the meeting. Size the window from the prompt instead.
        let promptCharacters = system.count + user.count
        let numCtx = OllamaContext.numCtx(promptCharacters: promptCharacters)
        if OllamaContext.exceedsLargestWindow(promptCharacters: promptCharacters) {
            NSLog("""
            [RecapService] transcript ~\(OllamaContext.estimatedTokens(promptCharacters: promptCharacters)) \
            tokens exceeds the \(numCtx)-token window — Ollama will drop the beginning of the meeting
            """)
        }

        var payload: [String: Any] = [
            "model": model,
            "stream": false,
            // Brief linger so a retry / metadata pass doesn't pay another cold load;
            // OllamaSidecar.stopAfterIdle still drops the serve process after the batch.
            // (keep_alive: 0 + thermal Mac was timing out ~12 min meetings at 180s.)
            "keep_alive": 90,
            "options": [
                "num_ctx": numCtx,
                // Match the cloud providers so the three backends drift less.
                "temperature": 0.2,
            ],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        // Reasoning models (Qwen3.x) answer in a separate `thinking` channel we
        // never show, and it is not free. Measured on an 11-minute meeting:
        // thinking on = 177 s and 5434 characters of reasoning; on the full recap
        // prompt it consumed the entire 16k window and returned content EMPTY —
        // a failed recap, not a slow one. Off = 62 s and a complete answer.
        //
        // Sent unconditionally rather than for an allowlist of known reasoning
        // models: the model name is free text in Settings, so any allowlist goes
        // stale exactly when someone picks a new reasoning model. Verified
        // accepted by Ollama for a non-thinking model too (qwen2.5:7b → 200);
        // `sendChat` falls back for older builds that reject the field.
        payload["think"] = false

        do {
            let message = try await sendChat(req: req, payload: payload)
            let content = message["content"] as? String ?? ""
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let thinking = message["thinking"] as? String, !thinking.isEmpty {
                // Model reasoned itself out of a reply — say which failure this is.
                NSLog("[RecapService] \(model) returned only `thinking` (\(thinking.count) chars), no content")
                throw RecapError.providerUnavailable("\(model) — модель ушла в рассуждения и не выдала конспект")
            }
            return content
        } catch let error as URLError where error.code == .timedOut {
            throw RecapError.timedOut
        }
    }

    /// POST the chat payload, retrying once without `think` if this Ollama build
    /// rejects the field — otherwise an old runtime would fail *every* recap.
    private func sendChat(req: URLRequest, payload: [String: Any]) async throws -> [String: Any] {
        var req = req
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        var (data, response) = try await session.data(for: req)

        if (response as? HTTPURLResponse)?.statusCode == 400, payload["think"] != nil {
            var retry = payload
            retry.removeValue(forKey: "think")
            NSLog("[RecapService] Ollama rejected `think` (400) — retrying without it")
            req.httpBody = try JSONSerialization.data(withJSONObject: retry)
            (data, response) = try await session.data(for: req)
        }

        try throwIfBadHTTP(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw RecapError.badJSON
        }
        return message
    }

    private func callOpenAI(apiKey: String, model: String, system: String, user: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        try throwIfBadHTTP(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw RecapError.badJSON
        }
        return content
    }

    private func callClaude(apiKey: String, model: String, system: String, user: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "temperature": 0.2,
            "system": system,
            "messages": [
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        try throwIfBadHTTP(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw RecapError.badJSON
        }
        let text = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        guard !text.isEmpty else { throw RecapError.badJSON }
        return text
    }

    // MARK: - Helpers

    private func throwIfBadHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RecapError.httpStatus(http.statusCode, body)
        }
    }
}

struct RecapPreferences {
    var provider: RecapProviderKind
    var prompt: String
    var ollamaModel: String
    var openAIModel: String
    var claudeModel: String
    var openAIKey: String?
    var claudeKey: String?
    var outputFormat: MarkdownOutputFormat

    static func fromShared() -> RecapPreferences {
        let p = Preferences.shared
        return RecapPreferences(
            provider: p.recapProvider,
            prompt: p.recapPrompt,
            ollamaModel: p.recapOllamaModel,
            openAIModel: p.recapOpenAIModel,
            claudeModel: p.recapClaudeModel,
            openAIKey: p.openAIAPIKey,
            claudeKey: p.claudeAPIKey,
            outputFormat: p.markdownOutputFormat
        )
    }
}
