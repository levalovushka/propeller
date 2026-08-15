import Foundation

/// # Что говорит строка Claude в настройках
///
/// Состояние **выводится**, не хранится: читаем конфиг Клода и отметку в момент
/// открытия настроек. Хранить его значило бы завести второй источник правды о
/// том, что лежит в чужом файле, — и разойтись с ним ровно тогда, когда чужое
/// приложение этот файл перепишет.
///
/// Здесь и решение, и слова: тест ставит «запись есть, отметки нет» и видит
/// строку, которую увидит человек. Тот же приём, что у `SetupPrompt`, и по той
/// же причине — цена ошибки тут не «некрасиво», а «человек застрял в состоянии,
/// из которого не видно выхода».
public enum ClaudeCellState: String, CaseIterable, Equatable, Sendable {
    /// Клода на машине нет. Предлагать нечего — только сказать, что бывает.
    case notInstalled
    /// Всё готово к нажатию.
    case offer
    /// Запись в конфиге есть, но Клод её ещё не прочитал.
    case restartNeeded
    /// Он нас запустил хотя бы раз.
    case connected
    /// Запись из конфига пропала, а отметка осталась. Чаще всего это значит,
    /// что Claude Desktop переписал свой конфиг целиком (известные репорты —
    /// Windows и Linux; для macOS подтверждения нет).
    case lost
    /// Последняя попытка записать конфиг не удалась. Причину разбираем мы, по
    /// телеметрии; человеку её знать незачем.
    case writeFailed

    /// Заголовок строки — имя приложения, и оно не меняется никогда.
    ///
    /// Группа называется «MCP», а не «Claude», потому что рядом встанут другие
    /// клиенты. Значит заголовок обязан отвечать на «кто это», а не на «что
    /// сейчас»: строка, у которой заголовок меняется вместе с состоянием, в
    /// списке из трёх таких перестаёт быть строкой про конкретное приложение.
    ///
    /// Именно «Claude Desktop», а не «Claude»: подключается не модель, а
    /// приложение на этом Mac, и рядом со строкой «Не установлен» это разница
    /// между «поставьте программу» и «у вас нет Клода».
    public static let rowTitle = "Claude Desktop"

    /// Тихая вторая строка — единственное, что меняется. Имени клиента в ней
    /// нет ни разу: оно уже стоит заголовком слева, и повторить его значит
    /// написать «Claude Desktop · Claude Desktop не установлен».
    public var subtitle: String {
        switch self {
        case .notInstalled:  return "Не установлен — приложение с\u{00A0}сайта Anthropic"
        case .offer:         return "Сможет читать ваши встречи"
        case .restartNeeded: return "Перезапустите, чтобы он увидел встречи"
        case .connected:     return "Подключён. Спросите его о\u{00A0}встречах"
        case .lost:          return "Подключение потерялось"
        case .writeFailed:   return "Не получилось подключить"
        }
    }

    /// Подпись кнопки — или nil, когда нажимать не на что.
    ///
    /// Кнопки нет в двух состояниях, и оба раза потому, что нажатие ничего не
    /// изменило бы: у «перезапустите» очередь за человеком и его чатами,
    /// у «подключён» — всё уже сделано. Кнопки «Перезапустить» нет намеренно:
    /// закрывать чужое приложение с открытыми разговорами мы не будем.
    public var actionTitle: String? {
        switch self {
        case .offer, .lost, .writeFailed: return "Подключить"
        case .notInstalled, .restartNeeded, .connected: return nil
        }
    }

    /// Ссылка на скачивание — только там, где скачивать и надо.
    public var linkURL: String? {
        self == .notInstalled ? ClaudeConnection.downloadURL : nil
    }

    public var showsCheckmark: Bool { self == .connected }

    /// Имя кадра в галерее и в Figma. Своё, а не `rawValue`: идентификаторы
    /// кадров живут в именах файлов, и там разрешены только `[a-z0-9-]`
    /// (`UIStateCatalogTests`).
    public var slug: String {
        switch self {
        case .notInstalled:  return "not-installed"
        case .offer:         return "offer"
        case .restartNeeded: return "restart-needed"
        case .connected:     return "connected"
        case .lost:          return "lost"
        case .writeFailed:   return "write-failed"
        }
    }
}

public enum ClaudeCellMachine {

    /// Единственное место, где решается, что человек увидит.
    ///
    /// Порядок веток — порядок правды. Не установлен — про конфиг говорить
    /// нечего, чей бы он ни был. Не записался — это ответ на нажатие, и он
    /// старше вывода из файлов. Дальше таблица: запись в конфиге × отметка.
    ///
    /// Состояния «Клод перезапустился, но не подключился» здесь нет и быть не
    /// может: отметки просто нет, и почему — мы не знаем. Поэтому
    /// «Перезапустите Claude» живёт до появления отметки, а не превращается в
    /// ошибку по таймеру.
    public static func state(
        claudeInstalled: Bool,
        configured: Bool,
        markedAt: Date?,
        lastWriteFailed: Bool
    ) -> ClaudeCellState {
        guard claudeInstalled else { return .notInstalled }
        if lastWriteFailed { return .writeFailed }
        switch (configured, markedAt != nil) {
        case (true, true):   return .connected
        case (true, false):  return .restartNeeded
        case (false, true):  return .lost
        case (false, false): return .offer
        }
    }
}
