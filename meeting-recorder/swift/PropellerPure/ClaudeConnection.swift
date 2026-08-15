import Foundation

/// # Подключение к Клоду — общие имена
///
/// Имя файла-отметки и ключ конфига лежат здесь, а не по месту использования,
/// потому что у них **два** пользователя в разных процессах: сервер отметку
/// ставит, приложение её читает и стирает. Разъехавшиеся имена дали бы вечное
/// «Перезапустите Claude» — состояние, из которого человек не может выйти и о
/// котором не может догадаться.
public enum ClaudeConnection {

    /// Каталог приложения в Application Support. Тот же, что у моделей и логов.
    public static let supportDirectoryName = "Meeting Recorder"

    /// Отметка «Claude Desktop запустил наш процесс».
    ///
    /// Важно, что она означает: stdio-серверы поднимаются вместе с приложением,
    /// поэтому отметка говорит «Клод нас видит», а не «человек нами
    /// пользуется». Для галочки в настройках этого достаточно; для любой
    /// статистики использования — нет.
    public static let markerFileName = "claude-mcp-seen"

    /// Ключ верхнего уровня в `claude_desktop_config.json`.
    public static let configKey = "mcpServers"

    /// Имя конфига Claude Desktop и каталог, в котором он лежит (относительно
    /// Application Support).
    public static let configDirectoryName = "Claude"
    public static let configFileName = "claude_desktop_config.json"
}
