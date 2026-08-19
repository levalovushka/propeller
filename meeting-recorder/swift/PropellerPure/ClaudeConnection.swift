import Foundation

/// # Подключение — общие имена
///
/// То, что нужно **двум** процессам сразу: сервер отметку ставит, приложение её
/// читает и стирает. Разъехавшиеся имена дали бы вечное ожидание — состояние, из
/// которого человек не может выйти и о котором не может догадаться.
///
/// Всё, что различается между клиентами — имя отметки, путь конфига, заголовок
/// строки, — переехало в `MCPClient`.
public enum ClaudeConnection {

    /// Каталог приложения в Application Support. Тот же, что у моделей и логов.
    public static let supportDirectoryName = "Meeting Recorder"

    /// Ключ верхнего уровня в `claude_desktop_config.json`.
    public static let configKey = "mcpServers"
}
