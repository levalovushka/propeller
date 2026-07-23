import Foundation

enum RecapProviderKind: String, CaseIterable, Identifiable {
    case auto
    case ollama
    case openai
    case claude
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .ollama: return "Ollama"
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .off: return "Off"
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

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return "LLM HTTP \(code): \(body.prefix(200))"
        case .emptyResponse:
            return "LLM returned an empty recap"
        case .badJSON:
            return "Could not parse LLM response"
        case .providerUnavailable(let name):
            return "\(name) is not available"
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
    Ты готовишь краткий рекап рабочей встречи на русском языке.

    Правила:
    - Не выдумывай факты, решения, договорённости и action items, которых нет в транскрипте или заметках пользователя.
    - Если есть заметки пользователя — это приоритетные якоря: раскрывай вокруг них контекст из транскрипта, не игнорируй их.
    - По контексту аккуратно исправляй очевидные ASR-ошибки (искажённые имена и термины, обрывки на границах реплик), не меняя смысл.
    - Не копируй транскрипт целиком — только сжатый рекап.
    - Структура ответа (пропускай пустые разделы):
      ## Кратко
      ## Решения
      ## Action items
      ## Открытые вопросы
    - Пиши плотным деловым языком без воды.
    - Блок «Заметки» в итоговый файл добавит система отдельно — не дублируй сырые заметки в ответе.
    """

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
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
            return await probeOllama() ? .success("ollama") : .failure(.noProvider)
        case .openai:
            return (openAIKey?.isEmpty == false) ? .success("openai") : .failure(.noProvider)
        case .claude:
            return (claudeKey?.isEmpty == false) ? .success("claude") : .failure(.noProvider)
        case .auto:
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
        let trimmed = transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTranscript) }

        let backend: String
        switch await resolveBackend(kind: prefs.provider, openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let name):
            backend = name
        }

        let prompt = prefs.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultPrompt
            : prefs.prompt

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

        let cleaned = stripCodeFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
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

        return Self.parseMetadata(stripCodeFences(raw))
    }

    private static func metadataPrompt(needTitle: Bool) -> String {
        let vocab = MeetingTags.vocabulary.joined(separator: ", ")
        return """
        Ты анализируешь готовое саммари рабочей встречи и возвращаешь СТРОГО один JSON-объект без пояснений и без markdown-ограждений.
        Формат: {"title": <строка или null>, "topics": [<строка>, ...], "tags": [<строка>, ...]}
        Правила:
        - title: суть встречи одной ёмкой фразой на русском, 3–7 слов.\(needTitle ? "" : " Заголовок уже задан пользователем — верни null.")
        - topics: 2–5 ключевых обсуждённых тем короткими фразами (пойдут в сабтайтл). Только то, что реально есть в саммари, не выдумывай.
        - tags: 0..N значений СТРОГО из списка: [\(vocab)]. Значения вне списка запрещены. Если ничего не подходит — пустой массив [].
        - Верни только JSON, никакого текста вокруг.
        """
    }

    private static func parseMetadata(_ text: String) -> RecapMetadata? {
        // Defensive: pull the first {...} block in case the model added stray text.
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = {
            guard let t = rawTitle, !t.isEmpty, t.lowercased() != "null" else { return nil }
            return t
        }()
        let topics = (obj["topics"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let allowed = Set(MeetingTags.vocabulary)
        let tags = (obj["tags"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { allowed.contains($0) } ?? []

        return RecapMetadata(title: title, topics: topics, tags: tags)
    }

    // MARK: - Prompt assembly

    private func buildUserMessage(
        title: String,
        transcriptMarkdown: String,
        speakers: [String],
        duration: TimeInterval,
        notes: String?
    ) -> String {
        var parts: [String] = []
        parts.append("Встреча: \(title.isEmpty ? "без названия" : title)")
        if duration > 0 {
            parts.append("Длительность: \(Int(duration / 60)) мин")
        }
        if !speakers.isEmpty {
            parts.append("Участники: \(speakers.joined(separator: ", "))")
        }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedNotes.isEmpty {
            parts.append("")
            parts.append("Заметки пользователя (якоря — приоритетнее болтовни в транскрипте):")
            parts.append(trimmedNotes)
        }
        parts.append("")
        parts.append("Транскрипт:")
        parts.append(transcriptMarkdown)
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
        let heading = title.isEmpty ? "Meeting recap" : "\(title) — рекап"
        let durationStr = duration > 0 ? "\(Int(duration / 60)) min" : ""

        var lines: [String] = []
        switch format {
        case .simple:
            lines.append("# \(heading)")
            lines.append("")
            lines.append("**Date:** \(todayISO())")
            if !durationStr.isEmpty {
                lines.append("**Duration:** \(durationStr)")
            }
            if !speakers.isEmpty {
                lines.append("**Participants:** \(speakers.joined(separator: ", "))")
            }
            lines.append("")
            lines.append(recapBody)
        case .obsidian:
            let safeTitle = heading.replacingOccurrences(of: "\"", with: "'")
            lines.append("---")
            lines.append("date: \(todayISO())")
            lines.append("title: \"\(safeTitle)\"")
            lines.append("duration: \"\(durationStr)\"")
            if !speakers.isEmpty {
                let quoted = speakers.map { "\"\($0)\"" }.joined(separator: ", ")
                lines.append("speakers: [\(quoted)]")
            }
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
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            // Unload the model shortly after generating so it doesn't sit in RAM
            // (~4–5 GB) between meetings and starve Zoom/Figma.
            "keep_alive": "10s",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        try throwIfBadHTTP(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw RecapError.badJSON
        }
        return content
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

    private func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNL = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNL)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func todayISO() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
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
