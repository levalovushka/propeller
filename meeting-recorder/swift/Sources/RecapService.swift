import Foundation
import PropellerMetrics
import PropellerPure

struct RecapResult {
    let path: String
    let provider: String
    let body: String
    /// Как генерация прошла — для телеметрии. У облачных бэкендов `draft`
    /// внутри пуст: их путь в этом релизе не тронут, длину ответа они не
    /// сообщают; сигнал по ним не шлётся.
    var stats: RecapRunStats?
}

/// Статистика одной генерации конспекта — те же оси, что в таблицах стенда,
/// чтобы прод-телеметрию и стендовые числа можно было читать одной головой.
struct RecapRunStats {
    /// Вызов, который писал конспект: у одиночного пути — он сам, у нарезки —
    /// свод. Извлечения из фрагментов сюда не попадают: их ретраи видны в логе,
    /// а ось телеметрии — судьба конспекта, не фрагмента.
    let draft: RecapGenerationPolicy.CallStats?
    let chunked: Bool
    let window: Int
    let seconds: Double
    /// Чей документ уехал читателю на пути нарезки. `nil` у одиночного пути:
    /// там выбирать не из чего, автор один.
    let author: RecapDigestGuard.Author?
    /// Почему документ отдали сборке. `nil`, когда его написал свод.
    let cause: RecapDigestGuard.Cause?
}

/// LLM meeting recap on top of a saved transcript markdown.
actor RecapService {
    static let shared = RecapService()

    /// Промпт извлечения. Короткий — и это замер, а не вкус.
    ///
    /// Предыдущая версия была втрое длиннее и подробно объясняла стиль. Прогон по
    /// восьми встречам (`tools/recap-lab`) показал, чего это стоило: 2525 → 5183
    /// символа правил уронили число найденных договорённостей с 28 до 18, и на
    /// трёх встречах из восьми конспект не нашёл ни одного решения. На
    /// четырёхмиллиардной модели **длина промпта конкурирует с полнотой**:
    /// внимание, потраченное на соблюдение запрета, не тратится на поиск пятой
    /// договорённости.
    ///
    /// Поэтому здесь только то, что нельзя перенести во второй проход: что
    /// искать, чего не выдумывать и какой формы должен быть ответ. Стиль —
    /// `polishPrompt`, термины — `TermCanon`. Эта версия находит 36
    /// договорённостей там, где длинная находила 18, а прежняя — 28.
    static let defaultPrompt = """
    Ты ведёшь конспект рабочей встречи. По транскрипту ниже собери то, о чём договорились.

    Собери ВСЕ договорённости, а не первые попавшиеся: они разбросаны по всему разговору, и на рабочей встрече их обычно пять и больше. Пропущенная договорённость — худшая ошибка конспекта.
    Срок и ответственного пиши, только если они прозвучали вслух. Не «к пятнице», если про пятницу никто не говорил; не «Система» и не «команда» вместо имени.
    Не выдумывай того, чего нет в транскрипте.
    Если пользователь приложил свои заметки — это то, что он счёл важным; вплетай их по смыслу, а не отдельным списком. Раздела «Заметки» не пиши: он собирается из его текста дословно и без тебя.

    Формат — Markdown: заголовки через ##, списки через дефис, жирное через **. Пустые секции опускай целиком. Шапку Date / Duration / Participants не добавляй.

    ## Итог
    2–3 предложения: зачем собирались и к чему пришли.

    ## Решения
    - Что решили. Каждый пункт — завершённая договорённость.

    ## Задачи
    - **Кто** — что делает — **к какому сроку**.

    ## Открытые вопросы
    - Что обсудили, но не решили; что заблокировано и чего ждёт.

    ## Ход обсуждения
    Разбор по темам, каждая с таймкодом начала в том виде, в каком он стоит в транскрипте. Контекст и аргументы, которых нет выше.

    ## Прочее
    Всё остальное, что стоит зафиксировать.
    """

    /// Второй проход: форма, и только форма.
    ///
    /// Вход — готовый конспект (около 4 000 символов вместо целой встречи),
    /// поэтому редактору можно рассказать о стиле много и всё равно уложиться в
    /// полминуты. Замер: пассив 17 → 1, «вода» 8 → 1, и ни одна из восьми встреч
    /// не потеряла при редактуре ни одного пункта.
    ///
    /// К этому тексту `RecapLint.editorNotes` дописывает **адреса** — цитаты тех
    /// мест, которые нашлись в этом конкретном конспекте. Правило с цитатой
    /// исполняется, то же правило девятым в списке — нет: общая редактура убрала
    /// 21 находку из 153, адресная — 49.
    static let polishPrompt = """
    Ты — редактор. Перед тобой готовый конспект встречи. Перепиши его по правилам ниже, ничего не добавляя и ничего не выбрасывая.

    НАКЛОНЕНИЕ
    Конспект рассказывает, что было, а не раздаёт указания. Изъявительное наклонение, третье лицо: «Левон чистит код», «Договорились отказаться от диплинков». Не «проведите очистку», не «используйте компоненты» — читатель конспекта не исполнитель.

    ЧТО НЕЛЬЗЯ ТРОГАТЬ
    - Состав: сколько пунктов пришло — столько и уходит. Ни одного нового, ни одного убранного, ни одного слитого с соседним.
    - Факты, имена, числа, таймкоды, названия секций и их порядок.
    - Термины и англицизмы участников: «дейлик», «флоу», «инстанс», «пайплайн», «джоба», «прод», «фича». Не переводи их и не расшифровывай.

    ЧТО ИСПРАВИТЬ
    - Пассив — в активный залог. «Было решено перейти» → «Решили перейти». Слова «утверждено», «согласовано», «отмечено», «выявлено», «зафиксировано» замени на глагол с действующим лицом.
    - Действующее лицо не выдумывай. Ставь имя, только если оно есть в самом конспекте; иначе пиши «Договорились…», «Решили…», «Отказались…». «Сторонники», «Стороны», «Участники», «Коллеги», «Команда», «Стейкхолдеры» в роли подлежащего запрещены — таких людей на встрече не было.
    - Срок не пересчитывай. Он либо стоит в конспекте словами со встречи, либо его нет вовсе: «~6 дней», «в течение недели», «(срок: немедленно)» — не пиши.
    - Канцелярит выкинь: «в рамках», «в целях», «с целью», «посредством», «путём», «данный», «является», «осуществляет», «реализация», «в части», «по итогам обсуждения».
    - Предложения длиннее 20 слов разбей на два, сохранив смысл целиком.
    - Общие слова («ключевой», «соответствующий», «следующие шаги», «приоритеты») убери, если без них понятно.
    - Задача, у которой вместо имени стоит «Система», «Команда» или «участник с ответственностью», остаётся без ответственного. Имя не придумывай.
    - Разметка: заголовки через ##, списки через дефис, жирное через **.

    Верни только переписанный конспект — без предисловий, без пояснений и без markdown-ограждений.
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

    /// Кто отвечает за саммари. Здесь остался один вопрос к сайдкару, сам выбор —
    /// `RecapBackendChoice.resolve`, где его достаёт тест.
    ///
    /// A reachable Ollama is not a usable one. We start the server ourselves, so
    /// it answers whether or not a model was ever pulled — and the recap then
    /// died on `HTTP 404: model not found` after *every* recording, with the
    /// backfill re-running it on a timer. The model has to be present for this
    /// backend to count as available; otherwise the caller gets `.noProvider`
    /// and the honest "download the model" empty state.
    ///
    /// Пригодность спрашивается **только** у своего провайдера: поднимать сайдкар
    /// ради выбора между двумя облачными ключами — это платить за ответ, который
    /// в нём не нужен.
    func resolveBackend(
        kind: RecapProviderKind,
        ollamaModel: String,
        openAIKey: String?,
        claudeKey: String?,
        openRouterKey: String?
    ) async -> Result<String, RecapSkipReason> {
        let usable = kind == .ollama ? await ollamaUsable(model: ollamaModel) : false
        return RecapBackendChoice.resolve(
            kind: kind,
            ollamaUsable: usable,
            openAIKey: openAIKey,
            claudeKey: claudeKey,
            openRouterKey: openRouterKey
        )
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
            claudeKey: prefs.claudeKey,
            openRouterKey: prefs.openRouterKey
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
        recordingID: String,
        prefs: RecapPreferences,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result<RecapResult, RecapSkipReason> {
        try await PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.recap) {
            let trimmed = transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyTranscript) }

            let backend: String
            switch await resolveBackend(kind: prefs.provider, ollamaModel: prefs.ollamaModel,
                                    openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey,
                                    openRouterKey: prefs.openRouterKey) {
            case .failure(let reason):
                return .failure(reason)
            case .success(let name):
                backend = name
            }

            let prompt = (prefs.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultPrompt
                : prefs.prompt) + Self.languageLock

            let userContent = RecapDocument.userMessage(
                title: title,
                transcriptMarkdown: trimmed,
                notes: notes,
                // Настоящие имена из журнала окна — единственные законные
                // исполнители (plan-people.md §6); плейсхолдеры состава не дают,
                // и промпт остаётся прежним.
                participants: RecapDocument.participants(fromTranscript: trimmed)
            )

            // Окно выбирается **один раз на встречу**, а не на вызов. Замерено:
            // второй вызов в том же окне платит 0,2 с за модель, в другом — 2,3 с,
            // потому что Ollama поднимает свежий llama-server (`OllamaContext`).
            let window = OllamaContext.numCtx(promptCharacters: prompt.count + userContent.count)
            let route = RecapRoute.of(
                backend: backend, promptCharacters: prompt.count + userContent.count
            )

            // Окно, в котором встреча **на самом деле** считалась. У нарезанной
            // это окно фрагмента, а не `window`: `window` для неё равен 32768,
            // потому что упёрся в потолок бакета — то самое окно, ради ухода от
            // которого её и нарезали. Второй проход с ним поднимал свежий
            // llama-server на 4,3 ГБ поверх ещё не выгруженного на 3,6.
            let started = Date()
            let draft: String
            let effectiveWindow: Int
            var draftStats: RecapGenerationPolicy.CallStats?
            var author: RecapDigestGuard.Author?
            var cause: RecapDigestGuard.Cause?
            switch route {
            case .chunked:
                let run = try await recapByChunks(
                    title: title, transcriptMarkdown: trimmed, notes: notes,
                    system: prompt, prefs: prefs, progress: progress
                )
                draft = run.recap
                effectiveWindow = run.window
                draftStats = run.stats
                author = run.author
                cause = run.cause
            case .localSingle:
                // Порог схлопывания есть только у локального пути: облако длину
                // ответа не сообщает, и его путь в этом релизе не тронут (Г3).
                let tracked = try await callOllamaTracked(
                    model: prefs.ollamaModel, system: prompt, user: userContent,
                    numCtx: window,
                    minReplyTokens: RecapGenerationPolicy.recapMinReplyTokens
                )
                draft = tracked.content
                draftStats = tracked.stats
                effectiveWindow = window
            case .cloudSingle:
                draft = try await callBackend(
                    backend, system: prompt, user: userContent, numCtx: window, prefs: prefs
                )
                effectiveWindow = window
            }

            let extracted = RecapMetadataParser.stripCodeFences(draft)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extracted.isEmpty else { throw RecapError.emptyResponse }

            // Написание имён приводится к составу **до** редактуры, а не
            // после: иначе «Марина» при ленточном «Marina Primer» уезжает
            // редактору находкой `assigneeOutsideRoster` — защита от
            // выдуманного ответственного тратится на верное имя, записанное в
            // другом алфавите. Замена детерминированная и узкая: точное
            // совпадение свёртки, падежи и регистр не трогаются (`PersonCanon`).
            let named = PersonCanon.normalize(
                extracted,
                roster: RecapDocument.participants(fromTranscript: trimmed)
            )

            let edited = await polished(
                named, transcript: trimmed, backend: backend,
                numCtx: effectiveWindow, prefs: prefs
            )

            // Выдуманный ответственный и выдуманный срок вырезаются здесь, а не
            // просятся у редактора: редактор исполняет треть адресов, и на
            // решётке моделей (`tools/recap-lab`, 2026-08-12) исполнитель-призрак
            // пережил редактуру в каждом прогоне. Всё, что можно снять без
            // модели, снимается без модели.
            let grounded = RecapLint.grounded(edited, transcript: trimmed)
            if !grounded.removed.isEmpty {
                NSLog("[RecapService] вырезано из конспекта: \(grounded.removed.joined(separator: " · "))")
            }

            // Термины канонизируются здесь, а не промптом: модель не может
            // починить то, чего не видела — в транскрипте уже стоит «майплайн».
            // Правится только конспект; транскрипт остаётся как сказано.
            let cleaned = TermCanon.normalize(grounded.recap)
            guard !cleaned.isEmpty else { throw RecapError.emptyResponse }

            let body = RecapDocument.wrapped(
                title: title,
                recapBody: cleaned,
                notes: notes,
                format: prefs.outputFormat
            )

            let path = try writeRecapFile(
                nextToTranscriptPath: transcriptPath,
                recordingID: recordingID,
                title: title,
                content: body
            )

            return .success(RecapResult(
                path: path, provider: backend, body: body,
                stats: RecapRunStats(
                    draft: draftStats, chunked: route == .chunked, window: effectiveWindow,
                    seconds: Date().timeIntervalSince(started), author: author, cause: cause
                )
            ))
        }
    }

    /// Извлечение фактов из одного фрагмента длинной встречи.
    ///
    /// Отдельный, ещё более узкий промпт: фрагменту не нужна структура конспекта,
    /// ему нужно, чтобы ничего не потерялось. Форму соберёт свод.
    private static let chunkExtractPrompt = """
    Ты читаешь фрагмент транскрипта рабочей встречи. Выпиши из него факты — без предисловий и без выводов.

    - ДОГОВОРИЛИСЬ: то, что участники проговорили как решение (кто-то предложил, другой согласился).
    - ЗАДАЧА: кто что делает. Срок — только если прозвучал вслух.
    - ОТКРЫТО: что обсудили и не решили.
    - ТЕМА: о чём говорили, с таймкодом начала в том виде, как он стоит в транскрипте.

    Каждый пункт с новой строки, начиная с метки. Ничего не выдумывай: фрагмент — единственный источник.
    Если в фрагменте нет ничего, кроме приветствий и болтовни, ответь одним словом: ПУСТО.
    """

    /// Конспект встречи, которая не помещается в окно.
    ///
    /// Раньше такая встреча доходила до модели наполовину — Ollama выбрасывала
    /// начало разговора, а приложение писало строчку в `NSLog` и отдавало
    /// уверенный конспект. Транскрипт режется по границам реплик, факты
    /// собираются с каждого фрагмента, а документ из них пишет **единый автор** —
    /// свод модели одним вызовом (решение владельца 2026-08-15, OPTIMIZATION.md,
    /// «Финал»: связность есть свойство одного автора, и сборка из фрагментов
    /// проигрывает ему по читаемости на всех замеренных жанрах).
    ///
    /// Сборка кодом (`RecapAssembly`, порт A5.1) при этом считается на тех же
    /// фактах — но не для показа: это невидимая линейка и запасной выход. У
    /// свода есть режим схлопывания, в котором он выбрасывает до пяти найденных
    /// пунктов, и `RecapDigestGuard` отдаёт документ сборке ровно тогда, когда
    /// это случилось. Цена страховки: у такого конспекта нет «Итога» — прозу
    /// пишет только модель. Заметки пользователя в документ кладёт
    /// `wrapRecapDocument` — дословно, отдельным блоком, чей бы документ ни
    /// победил (решение в RELEASE-1.16.5.md, «Решения до старта порта»).
    ///
    /// Все вызовы идут в одном окне (фрагмент подобран так, чтобы влезать в
    /// 16384): одна загрузка модели на всю встречу и 3,6 ГБ памяти вместо 4,3 ГБ,
    /// которые стоит окно 32768. **Свод — тоже вызов в этом окне**, а не в
    /// `OllamaContext.numCtx` по длине фактов: другое окно поднимет свежий
    /// llama-server поверх ещё не выгруженного.
    /// Возвращает конспект **и окно, в котором он посчитан**: дальше по встрече
    /// идёт ещё один вызов (редактура), и он обязан идти в том же окне. Иначе
    /// нарезка, сделанная ради 3,6 ГБ вместо 4,3, тут же оплачивает и то и другое.
    /// `stats` — про вызов свода; судьба фрагментов остаётся в логе.
    private func recapByChunks(
        title: String,
        transcriptMarkdown: String,
        notes: String?,
        system: String,
        prefs: RecapPreferences,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> (
        recap: String, window: Int,
        stats: RecapGenerationPolicy.CallStats?,
        author: RecapDigestGuard.Author, cause: RecapDigestGuard.Cause?
    ) {
        let chunks = TranscriptChunking.split(transcriptMarkdown)
        let extractSystem = Self.chunkExtractPrompt + Self.languageLock
        // Окно одно на все фрагменты — иначе каждый платил бы холодную загрузку.
        let window = OllamaContext.numCtx(
            promptCharacters: extractSystem.count + TranscriptChunking.charactersPerChunk + 200
        )

        var facts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // Минуты генерации не должны выглядеть зависанием: деталь активности
            // считает фрагменты (RELEASE-1.16.5.md, «Что едет»).
            progress?("Саммари: фрагмент \(index + 1) из \(chunks.count)…")
            let user = "Фрагмент \(index + 1) из \(chunks.count).\n\n\(chunk)"
            let raw: String
            do {
                // Порог извлечения ниже конспектного: ответ фрагмента короче
                // по построению (600 против 800, пороги со стенда).
                raw = try await callOllamaTracked(
                    model: prefs.ollamaModel, system: extractSystem, user: user, numCtx: window,
                    minReplyTokens: RecapGenerationPolicy.extractMinReplyTokens
                ).content
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Один упавший фрагмент — это дыра в конспекте, но целая встреча
                // без конспекта хуже. Дыра называется вслух в логе.
                debugLog("[RecapService] фрагмент \(index + 1)/\(chunks.count) не разобран: \(error)")
                continue
            }
            let text = RecapMetadataParser.stripCodeFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.uppercased().hasPrefix("ПУСТО") else { continue }
            facts.append(text)
        }

        guard !facts.isEmpty else { throw RecapError.emptyResponse }
        debugLog("[RecapService] встреча не влезла в окно: \(chunks.count) фрагментов, разобрано \(facts.count)")

        // Линейка считается до вызова и всегда: она бесплатна (кода на неё
        // микросекунды) и нужна ровно в тот момент, когда свод сорвался.
        let assembled = RecapAssembly.assemble(facts: facts.joined(separator: "\n"))

        var parts = ["Встреча: \(title.isEmpty ? "без названия" : title)"]
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedNotes.isEmpty {
            parts += ["", "Заметки пользователя (якоря — приоритетнее болтовни в транскрипте):", trimmedNotes]
        }
        parts += [
            "",
            "Ниже — факты, выписанные из транскрипта по частям, по порядку встречи.",
            "Это единственный источник: транскрипт целиком в контекст не помещается.",
            "",
            facts.joined(separator: "\n\n"),
            "",
            "Ответь строго на русском языке.",
        ]

        progress?("Саммари: собираем конспект…")
        let digest: (content: String, stats: RecapGenerationPolicy.CallStats)?
        do {
            digest = try await callOllamaTracked(
                model: prefs.ollamaModel, system: system, user: parts.joined(separator: "\n"),
                numCtx: window,
                minReplyTokens: RecapGenerationPolicy.recapMinReplyTokens
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Свод не состоялся вовсе — это ровно тот случай, ради которого
            // сборка и держится. Встреча без конспекта хуже конспекта без «Итога».
            debugLog("[RecapService] свод не удался, документ отдаёт сборка: \(error)")
            digest = nil
        }

        let decision = RecapDigestGuard.decide(
            digest: RecapMetadataParser.stripCodeFences(digest?.content ?? ""),
            collapsed: digest?.stats.collapsed ?? true,
            assembly: assembled
        )
        if let reason = decision.reason {
            debugLog("[RecapService] документ отдан сборке: \(reason)")
        } else {
            debugLog("[RecapService] документ пишет свод модели")
        }
        guard !decision.recap.isEmpty else { throw RecapError.emptyResponse }
        return (decision.recap, window, digest?.stats, decision.author, decision.cause)
    }

    /// Второй проход: та же модель правит форму по адресам от `RecapLint`.
    ///
    /// Никогда не бросает: конспект уже есть, и лучше отдать его неотредактированным,
    /// чем не отдать вовсе. Возвращает исходник и в двух случаях, когда редактура
    /// оказалась вредной:
    ///
    /// - **править нечего** — находок нет, и второй вызов был бы платой ни за что
    ///   (для короткого дейлика это половина всей работы);
    /// - **редактор съел содержание** — пунктов стало заметно меньше. В замере
    ///   такое случилось на двух встречах из восьми (17 → 12), и молча отдать
    ///   обрезанный конспект — ровно то, с чем эта работа боролась.
    private func polished(
        _ recap: String,
        transcript: String,
        backend: String,
        numCtx: Int,
        prefs: RecapPreferences
    ) async -> String {
        let findings = RecapLint.findings(
            recap: recap,
            transcript: transcript,
            participants: RecapDocument.participants(fromTranscript: transcript)
        )
        guard !findings.isEmpty else { return recap }

        let system = Self.polishPrompt + Self.languageLock
        let user = recap + RecapLint.editorNotes(findings)
        let raw: String
        do {
            raw = try await callBackend(backend, system: system, user: user, numCtx: numCtx, prefs: prefs)
        } catch {
            NSLog("[RecapService] редактура не удалась, отдаём конспект как есть: \(error)")
            return recap
        }

        let edited = RecapMetadataParser.stripCodeFences(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { return recap }

        let before = RecapLint.shape(of: recap)
        let after = RecapLint.shape(of: edited)
        if let loss = after.lostContentComparedTo(before) {
            NSLog("[RecapService] редактура потеряла содержание (\(loss)) — отдаём конспект как есть")
            return recap
        }
        NSLog("""
        [RecapService] редактура: \(findings.count) находок, \
        секций \(before.sections.count) → \(after.sections.count), \
        пунктов \(before.bullets) → \(after.bullets)
        """)
        return edited
    }

    private func callBackend(
        _ backend: String,
        system: String,
        user: String,
        numCtx: Int,
        prefs: RecapPreferences
    ) async throws -> String {
        switch backend {
        case "ollama":
            return try await callOllama(model: prefs.ollamaModel, system: system, user: user, numCtx: numCtx)
        case "openai":
            return try await callOpenAI(apiKey: prefs.openAIKey ?? "", model: prefs.openAIModel,
                                        system: system, user: user)
        case "claude":
            return try await callClaude(apiKey: prefs.claudeKey ?? "", model: prefs.claudeModel,
                                        system: system, user: user)
        case "openrouter":
            return try await callOpenAI(baseURL: Self.openRouterChatURL,
                                        apiKey: prefs.openRouterKey ?? "", model: prefs.openRouterModel,
                                        system: system, user: user)
        default:
            throw RecapSkipReason.noProvider
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
                                    openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey,
                                    openRouterKey: prefs.openRouterKey) {
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
        case "openrouter":
            raw = try await callOpenAI(baseURL: Self.openRouterChatURL,
                                       apiKey: prefs.openRouterKey ?? "", model: prefs.openRouterModel,
                                       system: system, user: user)
        default:
            throw RecapSkipReason.noProvider
        }

        let cleaned = TermCanon.normalize(
            RecapMetadataParser.stripCodeFences(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
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
                                    openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey,
                                    openRouterKey: prefs.openRouterKey) {
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
            case "openrouter": raw = try await callOpenAI(baseURL: Self.openRouterChatURL, apiKey: prefs.openRouterKey ?? "", model: prefs.openRouterModel, system: system, user: user)
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

    private func writeRecapFile(
        nextToTranscriptPath: String,
        recordingID: String,
        title: String,
        content: String
    ) throws -> String {
        let transcriptURL = URL(fileURLWithPath: nextToTranscriptPath)
        let dir = transcriptURL.deletingLastPathComponent()
        let slug = MeetingMarkdown.slugify(title.isEmpty ? recordingID : title)
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
    /// `numCtx` задаётся снаружи, когда встреча идёт в несколько вызовов: окно
    /// должно быть одним на всю встречу, иначе каждый вызов платит холодную
    /// загрузку модели (2,3 с против 0,2 с, замерено). Без него — как раньше,
    /// по длине этого запроса.
    private func callOllama(
        model: String,
        system: String,
        user: String,
        jsonMode: Bool = false,
        numCtx: Int? = nil
    ) async throws -> String {
        try await callOllamaTracked(
            model: model, system: system, user: user, jsonMode: jsonMode, numCtx: numCtx
        ).content
    }

    /// То же, плюс политика схлопывания и статистика вызова.
    ///
    /// `minReplyTokens` включает страховку со стенда (`RecapGenerationPolicy`,
    /// эталон — `promptlib.call_ollama`): ответ короче порога перегенерируется
    /// **один раз** на t=0,3 — при t=0 повтор на той же температуре вернул бы
    /// тот же огрызок, — и дальше уходит длинный из двух. Без порога — один
    /// детерминированный вызов, как раньше.
    private func callOllamaTracked(
        model: String,
        system: String,
        user: String,
        jsonMode: Bool = false,
        numCtx: Int? = nil,
        minReplyTokens: Int? = nil
    ) async throws -> (content: String, stats: RecapGenerationPolicy.CallStats) {
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
        let numCtx = numCtx ?? OllamaContext.numCtx(promptCharacters: promptCharacters)
        if OllamaContext.exceedsLargestWindow(promptCharacters: promptCharacters) {
            NSLog("""
            [RecapService] transcript ~\(OllamaContext.estimatedTokens(promptCharacters: promptCharacters)) \
            tokens exceeds the \(numCtx)-token window — Ollama will drop the beginning of the meeting
            """)
        }

        func makePayload(temperature: Double) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "stream": false,
            // Brief linger so a retry / metadata pass doesn't pay another cold load;
            // OllamaSidecar.stopAfterIdle still drops the serve process after the batch.
            // (keep_alive: 0 + thermal Mac was timing out ~12 min meetings at 180s.)
            "keep_alive": 90,
            "options": [
                "num_ctx": numCtx,
                // t=0 по замеру A4 (десять прогонов — один текст); повтор, если
                // случился, идёт на 0,3. Облачные бэкенды остаются на 0,2 — их
                // путь в этом релизе не тронут (RELEASE-1.16.5.md, Г3).
                "temperature": temperature,
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
        return payload
        }

        func once(temperature: Double) async throws -> RecapGenerationPolicy.ModelReply {
            let data = try await sendChat(req: req, payload: makePayload(temperature: temperature))
            let tokens = BoundaryResponses.chatReplyTokens(data: data)
            switch BoundaryResponses.readChatReply(data: data) {
            case .success(let content):
                return .init(content: content, replyTokens: tokens)
            case .failure(.reasonedItselfEmpty(let characters)):
                // Distinct from a plain empty answer: retrying with the same
                // settings burns the same minutes for the same nothing.
                NSLog("[RecapService] \(model) returned only `thinking` (\(characters) chars), no content")
                throw RecapError.providerUnavailable("\(model) — модель ушла в рассуждения и не выдала конспект")
            case .failure(.empty):
                // Пустой ответ длину всё же имеет (eval_count) — политика ретрая
                // увидит его как схлопнувшийся и даст один повтор.
                return .init(content: "", replyTokens: tokens)
            case .failure(.malformed):
                throw RecapError.badJSON
            }
        }

        do {
            let first = try await once(temperature: RecapGenerationPolicy.temperature)
            var retry: RecapGenerationPolicy.ModelReply?
            if RecapGenerationPolicy.wantsRetry(first: first, threshold: minReplyTokens) {
                try Task.checkCancellation()
                NSLog("""
                [RecapService] ответ схлопнулся (\(first.replyTokens ?? -1) токенов при пороге \
                \(minReplyTokens ?? 0)) — один повтор на t=\(RecapGenerationPolicy.retryTemperature)
                """)
                do {
                    retry = try await once(temperature: RecapGenerationPolicy.retryTemperature)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Первый ответ есть; отдать его — лучше, чем уронить встречу
                    // об неудавшийся повтор.
                    NSLog("[RecapService] повтор не удался, остаёмся с первым ответом: \(error)")
                }
            }
            let (winner, stats) = RecapGenerationPolicy.resolved(
                first: first, retry: retry, threshold: minReplyTokens
            )
            if stats.retried {
                NSLog("""
                [RecapService] повтор: \(stats.firstReplyTokens ?? -1) → \(stats.replyTokens ?? -1) токенов, \
                итог \(stats.collapsed ? "всё ещё схлопнут" : "здоров")
                """)
            }
            return (winner.content, stats)
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

    /// Адрес чата OpenAI. Вынесен рядом с OpenRouter, чтобы было видно: это
    /// один и тот же протокол с двумя адресами, а не два бэкенда.
    static let openAIChatURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// OpenRouter говорит на диалекте OpenAI — тот же путь, тот же `Bearer`,
    /// та же форма ответа. Поэтому у него нет своей функции: другой адрес и
    /// заголовок атрибуции, всё остальное — `callOpenAI`.
    ///
    /// Чего у него нет и не будет в этой версии: нарезки длинной встречи.
    /// Облачный путь отдаёт транскрипт одним вызовом при любой длине
    /// (`TranscriptChunking.needed(backend:)`), и у OpenRouter имя модели —
    /// свободный текст: человек вправе выбрать модель с окном 8k и получить
    /// HTTP 400 на двухчасовой встрече. Это выбор того, кто пришёл за выбором,
    /// а не дефолт: дефолт здесь локальный и нарезку умеет.
    static let openRouterChatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private func callOpenAI(
        baseURL: URL? = nil,
        apiKey: String,
        model: String,
        system: String,
        user: String
    ) async throws -> String {
        let url = baseURL ?? Self.openAIChatURL
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if url == Self.openRouterChatURL {
            // Атрибуция в дашборде OpenRouter: без неё в списке приложений
            // человек видит безымянный ключ и не знает, что его тратит.
            req.setValue("Propeller", forHTTPHeaderField: "X-Title")
            req.setValue("https://propeller.pragmatica.design", forHTTPHeaderField: "HTTP-Referer")
        }
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
        guard let failure = RecapBackendChoice.httpFailure(
            status: http.statusCode,
            body: { String(data: data, encoding: .utf8) ?? "" }
        ) else { return }
        throw failure
    }
}

struct RecapPreferences {
    var provider: RecapProviderKind
    var prompt: String
    var ollamaModel: String
    var openAIModel: String
    var claudeModel: String
    var openRouterModel: String
    var openAIKey: String?
    var claudeKey: String?
    var openRouterKey: String?
    var outputFormat: MarkdownOutputFormat

    static func fromShared() -> RecapPreferences {
        let p = Preferences.shared
        return RecapPreferences(
            provider: p.recapProvider,
            prompt: p.recapPrompt,
            ollamaModel: p.recapOllamaModel,
            openAIModel: p.recapOpenAIModel,
            claudeModel: p.recapClaudeModel,
            openRouterModel: p.recapOpenRouterModel,
            openAIKey: p.openAIAPIKey,
            claudeKey: p.claudeAPIKey,
            openRouterKey: p.openRouterAPIKey,
            outputFormat: p.markdownOutputFormat
        )
    }
}
