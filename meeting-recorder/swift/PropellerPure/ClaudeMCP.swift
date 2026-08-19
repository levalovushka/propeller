import Foundation

/// # Как Propeller выглядит изнутри разговора с Клодом
///
/// Здесь имя сервера, имена инструментов и их описания — данными, а не
/// строками, разбросанными по коду сервера. Причина ровно одна: **несущая
/// конструкция этой фичи — описания**. Модель решает, лезть ли к нам, читая
/// их; `instructions` сервера мы заполняем, но рассчитывать на него нельзя
/// (спека говорит, что клиент *MAY* добавить его в системный промпт, и для
/// Claude Desktop подтверждения нет). Значит слова, которые эту ставку несут,
/// должны лежать там, где тест может их увидеть, а человек — перечитать.
///
/// **Имена латиницей, описания по-русски.** Первое — требование: спека
/// ограничивает имя инструмента `A-Za-z0-9_-.`, а практический потолок Клода
/// жёстче — `^[a-zA-Z0-9_-]{1,64}$`, без точек, причём имя сервера склеивается
/// с именем инструмента в один идентификатор. Второе — наше решение: языкового
/// ограничения на описания нет нигде, а встречи здесь русские.
///
/// **Раскрытие прогрессивное, и это не украшение.** Поиск отдаёт строку на
/// встречу, рекап — страницу, транскрипт — фрагменты. Отдавать транскрипты
/// пачкой — самый быстрый способ взорвать контекст и сделать интеграцию
/// бесполезной ровно в том разговоре, ради которого она заводилась.
public enum ClaudeMCP {

    /// Имя сервера — оно же ключ в `mcpServers` конфига Клода и первая половина
    /// идентификатора инструмента у него в интерфейсе.
    public static let serverName = "Propeller"

    /// Версия протокола, на которой мы говорим, если клиент попросил что-то,
    /// чего мы не знаем. Спека требует именно этого: ответить той же, если
    /// поддерживаем, иначе — своей последней.
    public static let protocolVersion = "2025-06-18"

    /// Версии, которые мы согласны подтвердить клиенту дословно.
    public static let knownProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18",
    ]

    /// Что ответить на `initialize` в поле `protocolVersion`.
    public static func negotiatedProtocol(requested: String?) -> String {
        guard let requested, knownProtocolVersions.contains(requested) else {
            return protocolVersion
        }
        return requested
    }

    /// Подсказка серверу целиком. Заполнена честно и без надежды: если Desktop
    /// её донесёт — хорошо, если нет — работают описания инструментов.
    public static let instructions = """
        Архив рабочих встреч этого человека: расшифровки и саммари, лежат \
        локально. Если разговор идёт про его рабочий проект, встречу, \
        обсуждение, договорённости или сроки — начинать с search_meetings, а \
        не спрашивать, что было на встрече. Дальше в глубину: get_recap на \
        одну встречу, find_decisions и find_open_questions по теме, \
        get_transcript — за дословной цитатой.
        """

    // MARK: - Схема

    public struct Property: Codable, Equatable, Sendable {
        public let type: String
        public let description: String
        public let items: Items?

        public init(type: String, description: String, items: Items? = nil) {
            self.type = type
            self.description = description
            self.items = items
        }

        public struct Items: Codable, Equatable, Sendable {
            public let type: String
            public init(type: String) { self.type = type }
        }
    }

    public struct Schema: Codable, Equatable, Sendable {
        public let type: String
        public let properties: [String: Property]
        public let required: [String]

        public init(properties: [String: Property], required: [String] = []) {
            self.type = "object"
            self.properties = properties
            self.required = required
        }
    }

    public struct Tool: Codable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let inputSchema: Schema

        public init(name: String, description: String, inputSchema: Schema) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }
    }

    // MARK: - Имена

    /// Пересечение того, что разрешает спека, и того, что принимает Клод, минус
    /// то, чем мы решили не пользоваться: берём `[a-z0-9_]`, ≤ 64 знака.
    public static func isLegalName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains(String($0)) || ("0"..."9").contains(String($0)) || $0 == "_"
        }
    }

    /// Идентификатор, каким его склеивает Клод: имя сервера и имя инструмента.
    /// Проверяется отдельно, потому что потолок в 64 знака стоит именно на нём,
    /// а не на каждой половине.
    public static func qualifiedName(_ tool: String) -> String {
        "\(serverName)_\(tool)"
    }

    // MARK: - Инструменты

    public static let searchMeetings = "search_meetings"
    public static let getRecap = "get_recap"
    public static let findDecisions = "find_decisions"
    public static let findOpenQuestions = "find_open_questions"
    public static let getTranscript = "get_transcript"

    /// Два имени, которых требует ChatGPT.
    ///
    /// Для обычного разговора они не нужны — сервер без них подключается и
    /// работает. Но пути deep research и company knowledge зовут только их, со
    /// своей схемой: один строковый параметр, ответ с `id`, `title`, `url`.
    /// Разбор своих встреч глубоким поиском — как раз то, ради чего всё
    /// затевалось, поэтому мы их отдаём.
    public static let searchDocuments = "search"
    public static let fetchDocument = "fetch"

    /// Порядок — порядок глубины. Он же порядок, в котором их увидит модель.
    public static let tools: [Tool] = [
        Tool(
            name: searchMeetings,
            description: """
                Найти встречи в архиве Propeller — по словам, датам и участникам. \
                Точка входа: с неё начинать, как только разговор касается рабочего \
                проекта, встречи, обсуждения, договорённостей или сроков. Отдаёт \
                строку на встречу — id, дату, заголовок, темы, теги и пару строк \
                вокруг найденного, — то есть дёшево и широко. За подробностями \
                идти в get_recap с полученным id. Без запроса и дат отдаёт \
                последние встречи.
                """,
            inputSchema: Schema(
                properties: [
                    "query": Property(
                        type: "string",
                        description: "Слова, которые ищем в заголовках, расшифровках, заметках и саммари. Можно опустить."
                    ),
                    "from": Property(
                        type: "string",
                        description: "Не раньше этой даты, ГГГГ-ММ-ДД."
                    ),
                    "to": Property(
                        type: "string",
                        description: "Не позже этой даты, ГГГГ-ММ-ДД."
                    ),
                    "people": Property(
                        type: "array",
                        description: "Имена участников: встреча подходит, если в ней говорил кто-то из них.",
                        items: Property.Items(type: "string")
                    ),
                ]
            )
        ),
        Tool(
            name: getRecap,
            description: """
                Саммари одной встречи целиком: итог, решения, задачи, открытые \
                вопросы и ход обсуждения с таймкодами. Это обычная глубина \
                ответа — с неё отвечать на «что было на встрече», а не с \
                расшифровки. id берётся из search_meetings.
                """,
            inputSchema: Schema(
                properties: [
                    "id": Property(type: "string", description: "Идентификатор встречи из search_meetings."),
                ],
                required: ["id"]
            )
        ),
        Tool(
            name: findDecisions,
            description: """
                О чём договорились: решения со встреч, каждое со ссылкой на \
                встречу и таймкодом, если он был. topic сужает до темы — \
                «релиз», «найм», «бюджет». Без topic — последние решения по \
                всему архиву. Отвечать этим на «что мы решили», а не пересказом \
                саммари.
                """,
            inputSchema: Schema(
                properties: [
                    "topic": Property(type: "string", description: "Тема, к которой сузить. Можно опустить."),
                    "from": Property(type: "string", description: "Не раньше этой даты, ГГГГ-ММ-ДД."),
                    "to": Property(type: "string", description: "Не позже этой даты, ГГГГ-ММ-ДД."),
                ]
            )
        ),
        Tool(
            name: findOpenQuestions,
            description: """
                Что осталось нерешённым: открытые вопросы со встреч, со ссылкой \
                на встречу и таймкодом. topic сужает до темы. Этим отвечать на \
                «что зависло» и «о чём мы так и не договорились».
                """,
            inputSchema: Schema(
                properties: [
                    "topic": Property(type: "string", description: "Тема, к которой сузить. Можно опустить."),
                    "from": Property(type: "string", description: "Не раньше этой даты, ГГГГ-ММ-ДД."),
                    "to": Property(type: "string", description: "Не позже этой даты, ГГГГ-ММ-ДД."),
                ]
            )
        ),
        Tool(
            name: getTranscript,
            description: """
                Дословные фрагменты расшифровки одной встречи: по словам \
                (query), по говорящему (speaker) или вокруг таймкода (around, \
                ММ:СС). Нужен, когда важна точная формулировка. Расшифровка \
                целиком — только по явной просьбе (full): часовая встреча не \
                помещается в разговор, и после неё в нём не останется места ни \
                на что другое.
                """,
            inputSchema: Schema(
                properties: [
                    "id": Property(type: "string", description: "Идентификатор встречи из search_meetings."),
                    "query": Property(type: "string", description: "Слова, вокруг которых нужны реплики."),
                    "speaker": Property(type: "string", description: "Оставить только реплики этого говорящего."),
                    "around": Property(type: "string", description: "Таймкод ММ:СС или ЧЧ:ММ:СС — вернуть реплики вокруг него."),
                    "full": Property(type: "boolean", description: "Расшифровка целиком. Только по явной просьбе человека."),
                ],
                required: ["id"]
            )
        ),
    ]

    /// То же самое в терминах ChatGPT: `search` и `fetch`.
    ///
    /// Отдельными инструментами, а не переименованием своих: у них чужой
    /// контракт (единственный строковый параметр, ответ с `url` для сноски), и
    /// натягивать его на `search_meetings` с датами и участниками значило бы
    /// испортить оба.
    public static let openAITools: [Tool] = [
        Tool(
            name: searchDocuments,
            description: """
                Найти встречи в архиве Propeller по словам. Отдаёт список                 встреч — id, заголовок и ссылку, — по одному id из которого                 берётся полный текст через fetch. Для разбора рабочих                 договорённостей, сроков и обсуждений начинать отсюда.
                """,
            inputSchema: Schema(
                properties: [
                    "query": Property(type: "string", description: "Слова, которые ищем во встречах."),
                ],
                required: ["query"]
            )
        ),
        Tool(
            name: fetchDocument,
            description: """
                Полный текст одной встречи по id из search: саммари с решениями,                 задачами и открытыми вопросами, а если саммари нет — расшифровка.
                """,
            inputSchema: Schema(
                properties: [
                    "id": Property(type: "string", description: "Идентификатор встречи из search."),
                ],
                required: ["id"]
            )
        ),
    ]

    /// Что показать этому клиенту.
    ///
    /// Список — чистая функция от того, кто нас запустил, и это единственная
    /// причина, по которой мы вообще опознаём клиента. Клод остаётся при пяти
    /// инструментах: два почти-дубля в его списке разбавили бы описания, на
    /// которых всё держится, а deep research у него свой.
    public static func tools(for client: MCPClient?) -> [Tool] {
        client == .chatGPT ? tools + openAITools : tools
    }

    public static func tool(named name: String, for client: MCPClient? = nil) -> Tool? {
        tools(for: client).first { $0.name == name }
    }
}
