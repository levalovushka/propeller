import Foundation

/// # Наша запись в чужом файле
///
/// `claude_desktop_config.json` принадлежит Claude Desktop. Там лежат чужие
/// серверы, которые человек настраивал руками, и ключи верхнего уровня, про
/// которые мы ничего не знаем и знать не обязаны. Поэтому здесь **мёрж**, а не
/// запись: берём существующий объект, кладём в `mcpServers` одну запись,
/// отдаём обратно всё остальное байт в байт.
///
/// Форма вынесена отдельно от диска ровно поэтому: «чужие серверы уцелели» —
/// это то, что проверяется тестом, а не разговором с человеком, у которого они
/// не уцелели.
///
/// **Непонятный файл не переписывается.** Если JSON не разобрался, самый
/// дорогой из возможных ответов — уверенно записать поверх свой: человек
/// потеряет всё, что там было, и узнает об этом не сегодня. Разбор не удался —
/// значит подключение не удалось, и так и говорим.
public enum ClaudeConfigMerge {

    public struct Entry: Equatable, Sendable {
        public let name: String
        /// **Абсолютный** путь: официальный troubleshooting Клода требует
        /// именно его, относительный молча не заводится.
        public let command: String
        public let args: [String]
        public let env: [String: String]

        public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
            self.name = name
            self.command = command
            self.args = args
            self.env = env
        }

        var payload: [String: Any] {
            var out: [String: Any] = ["command": command]
            if !args.isEmpty { out["args"] = args }
            if !env.isEmpty { out["env"] = env }
            return out
        }
    }

    public enum Failure: String, Error, Equatable, Sendable {
        /// Файл есть, но это не JSON. Не трогаем.
        case unreadable
        /// Разобрался, но верхний уровень — не объект.
        case notAnObject
        /// `mcpServers` есть и это не объект.
        case serversNotAnObject
        /// Собрали, но не смогли сериализовать обратно.
        case notSerializable
        /// Путь к бинарю не абсолютный — Клод такой команды не запустит.
        case relativeCommand
    }

    /// Существующий файл (или его отсутствие) плюс наша запись → новый файл.
    public static func merged(into existing: Data?, entry: Entry) throws -> Data {
        guard entry.command.hasPrefix("/") else { throw Failure.relativeCommand }

        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) else {
                throw Failure.unreadable
            }
            guard let object = parsed as? [String: Any] else { throw Failure.notAnObject }
            root = object
        }

        var servers: [String: Any] = [:]
        if let current = root[ClaudeConnection.configKey] {
            guard let object = current as? [String: Any] else { throw Failure.serversNotAnObject }
            servers = object
        }
        servers[entry.name] = entry.payload
        root[ClaudeConnection.configKey] = servers

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { throw Failure.notSerializable }
        return data
    }

    /// Есть ли наша запись в конфиге прямо сейчас.
    ///
    /// Спрашивается **у файла**, а не у своего сохранённого флага: файл чужой,
    /// и его могли переписать, пока нас не спрашивали. Именно это и означает
    /// «Подключение потерялось».
    public static func contains(_ name: String, in existing: Data?) -> Bool {
        guard let existing, !existing.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let servers = root[ClaudeConnection.configKey] as? [String: Any],
              let entry = servers[name] as? [String: Any] else { return false }
        // Запись без команды — не запись: Клоду нечего запускать.
        return (entry["command"] as? String)?.isEmpty == false
    }

    /// Путь к бинарю, на который указывает наша запись, — чтобы отличить
    /// «подключено» от «подключено к тому, чего больше нет».
    public static func command(of name: String, in existing: Data?) -> String? {
        guard let existing, !existing.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let servers = root[ClaudeConnection.configKey] as? [String: Any],
              let entry = servers[name] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }
}
