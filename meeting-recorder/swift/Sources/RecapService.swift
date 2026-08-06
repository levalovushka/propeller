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
    - Не добавляй шапку Date / Duration / Participants (и аналоги) — дата уже в списке встреч, длительность и участники не дублируются в шапке.
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
    /// A reachable Ollama is not a usable one. We start the server ourselves, so
    /// it answers whether or not a model was ever pulled — and the recap then
    /// died on `HTTP 404: model not found` after *every* recording, with the
    /// backfill re-running it on a timer. The model has to be present for this
    /// backend to count as available; otherwise the caller gets `.noProvider`
    /// and the honest "download the model" empty state.
    func resolveBackend(
        kind: RecapProviderKind,
        ollamaModel: String,
        openAIKey: String?,
        claudeKey: String?
    ) async -> Result<String, RecapSkipReason> {
        switch kind {
        case .off:
            return .failure(.disabled)
        case .ollama:
            return await ollamaUsable(model: ollamaModel) ? .success("ollama") : .failure(.noProvider)
        case .openai:
            return (openAIKey?.isEmpty == false) ? .success("openai") : .failure(.noProvider)
        case .claude:
            return (claudeKey?.isEmpty == false) ? .success("claude") : .failure(.noProvider)
        case .auto:
            if await ollamaUsable(model: ollamaModel) { return .success("ollama") }
            if openAIKey?.isEmpty == false { return .success("openai") }
            if claudeKey?.isEmpty == false { return .success("claude") }
            return .failure(.noProvider)
        }
    }

    /// Cheapest question first: nothing to serve if the weights are not on disk.
    ///
    /// The old order started `ollama serve` — unpacking the ~0.5 GB runtime if
    /// that had not happened yet — and only then discovered there was no model
    /// and gave up. On a Mac where the user never installed one, every catch-up
    /// pass paid for that. `isModelInstalled` reads the manifest (or asks a
    /// server that already happens to be up) and spawns nothing.
    private func ollamaUsable(model: String) async -> Bool {
        guard await OllamaSidecar.shared.isModelInstalled(model) else { return false }
        await OllamaSidecar.shared.ensureServerRunning()
        return await probeOllama()
    }

    /// Is there any way to make a summary right now? Same resolution the recap
    /// itself uses, without generating anything.
    func summaryProviderReady(prefs: RecapPreferences) async -> Bool {
        switch await resolveBackend(
            kind: prefs.provider,
            ollamaModel: prefs.ollamaModel,
            openAIKey: prefs.openAIKey,
            claudeKey: prefs.claudeKey
        ) {
        case .success: return true
        case .failure: return false
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
            switch await resolveBackend(kind: prefs.provider, ollamaModel: prefs.ollamaModel,
                                    openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey) {
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

    /// Rewrite a fragment the user selected in the summary — «короче» / «подробнее».
    ///
    /// The same backend the summary itself came from, so «короче» never means
    /// «отправить кусок вашей встречи в облако» on a machine where everything
    /// else is local. Returns the replacement text and nothing else: this lands
    /// straight into a text view, so a preamble («Вот сокращённый вариант:»)
    /// would be typed into the meeting.
    ///
    /// `transcript` is what «Подробнее» is for: the detail it adds has to come
    /// from what was said, not from the model's sense of what usually follows a
    /// sentence like this one. «Короче» passes nil — it has everything it needs
    /// in the fragment, and handing it the meeting would invite it to bring
    /// things back in while cutting.
    func rewriteFragment(
        _ fragment: String,
        instruction: String,
        transcript: String?,
        prefs: RecapPreferences
    ) async throws -> String {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fragment }

        let backend: String
        switch await resolveBackend(kind: prefs.provider, ollamaModel: prefs.ollamaModel,
                                    openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey) {
        case .failure(let reason): throw reason
        case .success(let name):   backend = name
        }

        let system = """
        Ты редактируешь фрагмент конспекта встречи.
        \(instruction)
        Верни только переписанный фрагмент — один абзац, без пояснений, без кавычек, \
        без заголовков, без списков, без пустых строк и без markdown-ограждений.
        Если в исходном фрагменте было жирное (`**…**`), сохрани его так же; \
        новую структурную разметку не вводи.
        """ + Self.languageLock

        let user: String
        if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user = """
            РАСШИФРОВКА ВСТРЕЧИ
            \(transcript)

            ФРАГМЕНТ КОНСПЕКТА
            \(trimmed)
            """
        } else {
            user = trimmed
        }

        let raw: String
        switch backend {
        case "ollama":
            raw = try await callOllama(model: prefs.ollamaModel, system: system, user: user)
        case "openai":
            raw = try await callOpenAI(apiKey: prefs.openAIKey ?? "", model: prefs.openAIModel,
                                       system: system, user: user)
        case "claude":
            raw = try await callClaude(apiKey: prefs.claudeKey ?? "", model: prefs.claudeModel,
                                       system: system, user: user)
        default:
            throw RecapSkipReason.noProvider
        }

        let cleaned = RecapMetadataParser.stripCodeFences(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RecapError.emptyResponse }
        return cleaned
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
        switch await resolveBackend(kind: prefs.provider, ollamaModel: prefs.ollamaModel,
                                    openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey) {
        case .failure: return nil
        case .success(let name): backend = name
        }

        let system = Self.metadataPrompt(needTitle: needTitle)
        let user = "Саммари встречи:\n\n\(trimmed)"

        let raw: String
        do {
            switch backend {
            case "ollama": raw = try await callOllama(model: prefs.ollamaModel, system: system, user: user, jsonMode: true)
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
        ) else {
            // Silence here used to cost a meeting its topics permanently.
            NSLog("[RecapService] metadata unparseable, first 300 chars: \(raw.prefix(300))")
            return nil
        }
        return RecapMetadata(title: parsed.title, topics: parsed.topics, tags: parsed.tags)
    }

    /// The topics rules are longer than they look like they need to be, and each
    /// line is there because the shorter version was measured and failed.
    ///
    /// Asking for «3–6 слов» produced 7.2 words a topic across the archive's own
    /// recaps (max 9), because a 4B model reads a range as a suggestion and a
    /// recap's decision bullet as something to preserve. Naming the wordy shapes
    /// («с фокусом на…», «в пользу…») and forbidding subordinate clauses moved it
    /// to 6.5 — still a row four lines tall. What actually worked was showing the
    /// compression: with the four examples below it lands at 4.1 words (max 6).
    ///
    /// The examples are about a warehouse on purpose. The first set was written
    /// from real meetings, and the model copied them wholesale onto unrelated
    /// calls — «данные вместо заглушек» arrived on a summary that had neither.
    /// A domain nowhere near the user's work cannot be pasted in unnoticed.
    ///
    /// Compressing harder is not better either: making the model draft and then
    /// squeeze got 2.6 words and turned every meeting into filing labels
    /// («структура экранов», «этапы реализации») — which is the row saying
    /// nothing in fewer words. Hence «пункт — факт, а не рубрика».
    private static func metadataPrompt(needTitle: Bool) -> String {
        let vocab = MeetingTags.vocabulary.joined(separator: ", ")
        return """
        Ты анализируешь готовое саммари рабочей встречи и возвращаешь СТРОГО один JSON-объект без пояснений и без markdown-ограждений.
        Формат: {"title": <строка или null>, "topics": [<строка>, ...], "tags": [<строка>, ...]}
        Правила:
        - title: суть встречи одной ёмкой фразой на русском, 3–7 слов.\(needTitle ? "" : " Заголовок уже задан пользователем — верни null.")
        - topics: 2–3 пункта — подпись встречи в списке. Каждый пункт — именная группа из 2–5 слов, без точки в конце.
          Сформулируй по сути, потом сократи: отрезается хвост, ядро остаётся.
          Примеры сокращения — они про длину и форму фразы; их слова и тема в ответ не попадают:
            «Переход на новую систему учёта заказов с фокусом на склад» → «учёт заказов под склад»
            «Отказ от бумажных накладных в пользу мобильного приложения» → «отказ от бумажных накладных»
            «Замена устаревших ценников на актуальные электронные» → «электронные ценники вместо бумажных»
            «Унификация маршрутов доставки и подтверждение графика курьеров» → «унификация маршрутов доставки»
          Слова «полностью», «актуальный», «текущий», «ключевой», «система», «структура», «модель», «внедрение», «подготовка» — выкидывай, если без них понятно.
          Предпочитай существительные глаголам. Придаточных нет. Союз «и» — не больше одного на весь список.
          Пункт — факт, а не рубрика: «этапы реализации», «структура экранов», «контент» — так нельзя.
          С большой буквы — только первый пункт; остальные со строчной, кроме имён, названий и аббревиатур (VK, Rich-text, Figma).
          Сначала ключевые решения. Если решений не было — конкретные темы обсуждения, не процесс («обсудили», «договорились», «наметили», «проговорили»).
          Без воды и общих слов: «этапы», «следующие шаги», «приоритеты», «вопросы», «результаты». Только то, что реально есть в саммари. Без китайского и других языков.
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

        // Drop stale recaps for this recording (the slug changes on rename), using
        // the same matcher as every other recap lookup.
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in contents
            where RecapFile.isRecap(file.lastPathComponent, for: recordingID)
                && file.lastPathComponent != filename {
                try? fm.removeItem(at: file)
            }
        }

        try content.write(to: filepath, atomically: true, encoding: .utf8)
        return filepath.path
    }

    // MARK: - Providers

    /// `jsonMode` switches Ollama to constrained JSON decoding. Used for the
    /// metadata pass only — the recap itself is markdown prose.
    private func callOllama(
        model: String,
        system: String,
        user: String,
        jsonMode: Bool = false
    ) async throws -> String {
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
        if jsonMode {
            // Without this the model emitted `"tags": [1:1]` — the 1:1 tag from
            // our own vocabulary, unquoted — which made the whole object
            // unparseable and silently cost the meeting its topics and tags.
            payload["format"] = "json"
        }

        do {
            let data = try await sendChat(req: req, payload: payload)
            switch BoundaryResponses.readChatReply(data: data) {
            case .success(let content):
                return content
            case .failure(.reasonedItselfEmpty(let characters)):
                // Distinct from a plain empty answer: retrying with the same
                // settings burns the same minutes for the same nothing.
                NSLog("[RecapService] \(model) returned only `thinking` (\(characters) chars), no content")
                throw RecapError.providerUnavailable("\(model) — модель ушла в рассуждения и не выдала конспект")
            case .failure(.empty):
                return ""
            case .failure(.malformed):
                throw RecapError.badJSON
            }
        } catch let error as URLError where error.code == .timedOut {
            throw RecapError.timedOut
        }
    }

    /// POST the chat payload, retrying once without `think` if this Ollama build
    /// rejects the field — otherwise an old runtime would fail *every* recap.
    private func sendChat(req: URLRequest, payload: [String: Any]) async throws -> Data {
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
        // Interpretation belongs to `BoundaryResponses`; this only transports.
        return data
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
