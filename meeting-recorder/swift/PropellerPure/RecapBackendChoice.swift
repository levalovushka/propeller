import Foundation

/// Кто отвечает за саммари, чем это может кончиться и каким путём встреча
/// пойдёт. Три решения, которые раньше жили в `RecapService` — то есть в
/// executable-таргете, куда тест не дотягивается, — и проверялись руками.
///
/// Сеть и сайдкар остались снаружи: здесь только выбор при известных ответах на
/// «есть ли ключ» и «пригодна ли Ollama». Это и есть граница — вопрос «какая
/// модель отвечает» решается арифметикой, а не запросом.

/// Кто пишет саммари. Выключателя здесь нет и быть не может.
///
/// «Выкл» был пятым вариантом этого пикера, и он отключал ровно то, зачем
/// приложение существует: расшифровка без конспекта — это файл, который никто не
/// откроет. Выбор провайдера — да, выбор «а давайте без саммари» — нет, ровно
/// как нет гейта на скачивание модели (`CLAUDE.md`: «нет LLM» не является
/// законным состоянием приложения).
///
/// «Авто» ушло следом (2026-08-07). Оно означало «Ollama, а если её нет — тот
/// облачный, у кого нашёлся ключ», то есть настройку, по которой нельзя было
/// сказать, куда уедет транскрипт. Для локального по умолчанию приложения это
/// не удобство, а неопределённость в самом чувствительном месте. Локальная
/// модель приезжает сама и чинится сама, так что дефолт — `ollama`, и он
/// означает ровно себя.
///
/// Сохранённые `"off"` и `"auto"` переписываются на `.ollama` при чтении —
/// `Preferences.recapProvider`.
///
/// OpenRouter (2026-08-20) — четвёртый и единственный, про кого нельзя сказать
/// заранее, чей сервер увидит транскрипт: маршрутизатор на то и маршрутизатор.
/// Тем же аргументом убрали «Авто», и разница здесь не в аргументе, а в том,
/// кто его выбирает: «Авто» было настройкой по умолчанию у всех, а OpenRouter
/// человек включает руками, вписывая имя модели с префиксом вендора. Дефолт
/// остаётся локальным, и цена выбора — на том, кто выбрал.
///
/// Отдельным вариантом, а не полем «свой адрес» у OpenAI: провайдер — это ось
/// телеметрии (`Analytics.environment`), заголовок настроек и ответ на вопрос
/// «куда уехала эта встреча». Спрятанный base URL сделал бы все три ответа
/// неправдой при том же значении в префах.
public enum RecapProviderKind: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case openai
    case claude
    case openrouter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .openrouter: return "OpenRouter"
        }
    }
}

/// Почему саммари не сделали. Обе причины — про то, чего нет снаружи, ни одна не
/// про наше решение: ветка `.disabled` ушла вместе с «Выкл», потому что после
/// него её нечем было произвести.
public enum RecapSkipReason: Error, Equatable, Sendable {
    case noProvider
    case emptyTranscript
}

public enum RecapError: LocalizedError {
    case httpStatus(Int, String)
    case emptyResponse
    case badJSON
    case providerUnavailable(String)
    case timedOut

    public var errorDescription: String? {
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

public enum RecapBackendChoice {

    /// Какой бэкенд отвечает — при уже известном ответе про Ollama.
    ///
    /// `ollamaUsable` входом, а не вопросом изнутри: доступная Ollama — это не
    /// то же, что пригодная (сервер поднимаем мы сами, он отвечает и без
    /// скачанной модели, и саммари умирало на `HTTP 404: model not found`
    /// после каждой записи). Спросить это можно только у сайдкара, поэтому
    /// вопрос задаёт вызывающий, а выбор считается здесь.
    ///
    /// Ключ у облачных: пустая строка — это отсутствие ключа, а не ключ.
    public static func resolve(
        kind: RecapProviderKind,
        ollamaUsable: Bool,
        openAIKey: String?,
        claudeKey: String?,
        openRouterKey: String?
    ) -> Result<String, RecapSkipReason> {
        switch kind {
        case .ollama:
            return ollamaUsable ? .success("ollama") : .failure(.noProvider)
        case .openai:
            return keyed("openai", openAIKey)
        case .claude:
            return keyed("claude", claudeKey)
        case .openrouter:
            return keyed("openrouter", openRouterKey)
        }
    }

    private static func keyed(
        _ backend: String, _ key: String?
    ) -> Result<String, RecapSkipReason> {
        (key?.isEmpty == false) ? .success(backend) : .failure(.noProvider)
    }

    /// Ответ, который нельзя считать ответом.
    ///
    /// Тело читается только у отказа: на успехе декодировать его незачем, а
    /// ответы бывают в мегабайты. Отсюда замыкание, а не строка.
    public static func httpFailure(
        status: Int, body: () -> String
    ) -> RecapError? {
        (200..<300).contains(status) ? nil : .httpStatus(status, body())
    }
}

/// Каким путём пойдёт встреча. Раньше это были три ветки `if` внутри
/// `generateRecap`, и то, что порог **используется**, не проверял никто:
/// `TranscriptChunking.needed` покрыт тестами, а выбор пути ловился руками.
public enum RecapRoute: Equatable, Sendable {
    /// Нарезка по фрагментам со сводом — только у локального пути.
    case chunked
    /// Один вызов Ollama с порогом схлопывания.
    case localSingle
    /// Один вызов облачного бэкенда. Длину ответа облако не сообщает, порога у
    /// него нет, и нарезки тоже: его путь в 1.16.5 не тронут.
    case cloudSingle

    public static func of(backend: String, promptCharacters: Int) -> RecapRoute {
        guard backend == "ollama" else { return .cloudSingle }
        return TranscriptChunking.needed(
            backend: backend, promptCharacters: promptCharacters
        ) ? .chunked : .localSingle
    }
}
