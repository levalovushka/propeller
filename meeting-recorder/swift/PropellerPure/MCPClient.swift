import Foundation

/// # Кто именно подключается
///
/// Клиентов у одного и того же сервера теперь двое, и различий между ними ровно
/// столько, сколько перечислено здесь: куда пишет кнопка, как называется строка,
/// какой файл-отметку трогает сервер и стартует ли клиент сервер сразу.
///
/// Всё остальное — инструменты, архив, телеметрия — общее, и это главное
/// свойство фичи: второй клиент стоил одного перечисления, а не второго сервера.
///
/// **`rawValue` — это ещё и токен в `env` нашей записи.** Сервер по нему узнаёт,
/// чей конфиг его запустил, не гадая по `clientInfo`. Менять значения нельзя:
/// они лежат в чужих конфигах на машинах людей.
public enum MCPClient: String, CaseIterable, Equatable, Sendable {
    case claudeDesktop = "claude"
    case chatGPT = "chatgpt"

    /// Переменная окружения, которой мы подписываем свою запись в чужом конфиге.
    public static let envKey = "PROPELLER_MCP_CLIENT"

    /// Заголовок строки в настройках — имя приложения, и он не меняется никогда.
    ///
    /// Именно «Claude Desktop», а не «Claude»: подключается не модель, а
    /// приложение на этом Mac. У ChatGPT то же основание, но короче — «ChatGPT
    /// Desktop» на macOS никто не говорит.
    public var rowTitle: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .chatGPT:       return "ChatGPT"
        }
    }

    /// Короткое имя — для рельса, где строка узкая и «Desktop» ничего не
    /// добавляет: там вопрос задают, а не перечисляют установленное.
    public var shortName: String {
        switch self {
        case .claudeDesktop: return "Claude"
        case .chatGPT:       return "ChatGPT"
        }
    }

    /// Чьё это приложение — на случай, когда его нет и надо сказать, где взять.
    public var vendor: String {
        switch self {
        case .claudeDesktop: return "Anthropic"
        case .chatGPT:       return "OpenAI"
        }
    }

    /// Файл-отметка «этот клиент запустил наш процесс».
    ///
    /// У каждого клиента свой: одна отметка на двоих зажигала бы галочку у того,
    /// кого не подключали. Имя Клода историческое — оно уже лежит на дисках
    /// людей, подключившихся до появления второго клиента, и переименование
    /// стоило бы им вечного «перезапустите».
    public var markerFileName: String {
        switch self {
        case .claudeDesktop: return "claude-mcp-seen"
        case .chatGPT:       return "chatgpt-mcp-seen"
        }
    }

    /// Поднимает ли клиент stdio-сервер сразу, как только запустился сам.
    ///
    /// Claude Desktop — да, поэтому у него отметка появляется после перезапуска
    /// и строка просит перезапустить. Codex — **нет**: он запускает сервер, когда
    /// собирается им воспользоваться. Значит отметки не будет, пока человек не
    /// спросит про встречи, и просить перезапуск бессмысленно — он ничего не
    /// приблизит.
    ///
    /// Официальный рычаг сделать старт ранним есть — `required = true` в секции
    /// Codex. Мы его не берём: если наш бинарь не поднимется, обязательный
    /// сервер утащит за собой запуск чужого Codex. Платить чужим приложением за
    /// нашу галочку не за что.
    public var startsEagerly: Bool {
        switch self {
        case .claudeDesktop: return true
        case .chatGPT:       return false
        }
    }

    /// Где лежит конфиг, в который пишет кнопка.
    ///
    /// Корни разные, поэтому это не одна строка, а перечисление: путь собирает
    /// сторона, у которой есть `FileManager`, — здесь только знание.
    public enum ConfigLocation: Hashable, Sendable {
        /// Внутри `~/Library/Application Support`: каталог и имя файла.
        case applicationSupport(directory: String, file: String)
        /// Внутри домашнего каталога: путь относительно `~`.
        case home(path: String)
    }

    /// Чем написан чужой конфиг. От этого зависит, каким мёржем в него писать:
    /// JSON разбирается и собирается целиком, TOML — только дописыванием секции,
    /// потому что его правят руками и в нём живут комментарии.
    public enum Format: Equatable, Sendable { case json, toml }

    public var configFormat: Format {
        switch self {
        case .claudeDesktop: return .json
        case .chatGPT:       return .toml
        }
    }

    public var configLocation: ConfigLocation {
        switch self {
        case .claudeDesktop:
            return .applicationSupport(directory: "Claude", file: "claude_desktop_config.json")
        // Один файл на трёх клиентов: приложение ChatGPT, Codex CLI и
        // расширение для IDE делят эту конфигурацию. У Клода так не вышло —
        // там Desktop и Code это два разных места.
        case .chatGPT:
            return .home(path: ".codex/config.toml")
        }
    }

    /// Идентификатор бандла — чтобы спросить у Launch Services, стоит ли он.
    public var bundleID: String {
        switch self {
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        case .chatGPT:       return "com.openai.chat"
        }
    }

    /// Запасной ответ на «стоит ли», когда Launch Services ещё не увидел
    /// свежепоставленное приложение.
    public var applicationPath: String {
        switch self {
        case .claudeDesktop: return "/Applications/Claude.app"
        case .chatGPT:       return "/Applications/ChatGPT.app"
        }
    }

    /// Каталог, наличие которого означает, что клиент на машине есть, даже если
    /// приложения нет.
    ///
    /// Нужен ровно ChatGPT и ровно потому, что его конфиг общий: человек с
    /// одним Codex CLI и без приложения — полноправный пользователь фичи, а
    /// строка «Не установлен» сказала бы ему неправду.
    public var alternativeHomeMarker: String? {
        switch self {
        case .claudeDesktop: return nil
        case .chatGPT:       return ".codex"
        }
    }

    /// Кто нас запустил, по подписи в окружении или по тому, как назвался клиент.
    ///
    /// Окружение первое: его написали мы сами, когда подключали, и оно точное.
    /// `clientInfo` — запасной путь для записи, добавленной руками мимо кнопки.
    public static func resolve(env: [String: String], clientName: String?) -> MCPClient? {
        if let token = env[envKey], let client = MCPClient(rawValue: token) { return client }
        guard let name = clientName?.lowercased(), !name.isEmpty else { return nil }
        if name.contains("claude") { return .claudeDesktop }
        if name.contains("codex") || name.contains("chatgpt") || name.contains("openai") {
            return .chatGPT
        }
        return nil
    }
}
