import Foundation

/// # Наша секция в чужом TOML
///
/// `~/.codex/config.toml` принадлежит человеку, а не приложению. Там его
/// комментарии, его порядок ключей и его доверенные проекты — файл, который
/// правят руками. Поэтому здесь **не** «разобрать и переписать», а дописывание
/// секции: всё, что не наше, остаётся байт в байт, включая пустые строки.
///
/// Разбирать было бы и нечем: TOML Foundation не читает, и «распарсить и
/// сериализовать обратно» означало бы либо писать парсер, либо снести человеку
/// комментарии. Второе — молча и навсегда.
///
/// Отсюда же граница честности: мы умеем ровно две вещи — найти свою секцию по
/// заголовку и заменить её строки. Всё остальное в файле для нас текст.
public enum CodexConfigMerge {

    public struct Entry: Equatable, Sendable {
        public let name: String
        /// **Абсолютный** путь. Codex запускает команду сам; относительный путь
        /// разрешался бы от его рабочего каталога, а не от нашего.
        public let command: String
        public let args: [String]
        public let env: [String: String]

        public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
            self.name = name
            self.command = command
            self.args = args
            self.env = env
        }
    }

    public enum Failure: String, Error, Equatable, Sendable {
        /// Путь к бинарю не абсолютный.
        case relativeCommand
        /// Имя секции не из тех, что можно написать без кавычек. Мы такие не
        /// заводим — проверка стоит, чтобы это осталось правдой.
        case unsafeName
    }

    // MARK: - Форма

    /// Ключи по алфавиту — так пишет сам Codex (`args` раньше `command`), и
    /// разница в порядке читалась бы как чужая правка.
    static func render(_ entry: Entry) -> [String] {
        var lines = ["[mcp_servers.\(entry.name)]"]
        if !entry.args.isEmpty {
            lines.append("args = [" + entry.args.map(quoted).joined(separator: ", ") + "]")
        }
        lines.append("command = \(quoted(entry.command))")
        if !entry.env.isEmpty {
            let pairs = entry.env.keys.sorted().map { "\($0) = \(quoted(entry.env[$0]!))" }
            lines.append("env = { " + pairs.joined(separator: ", ") + " }")
        }
        return lines
    }

    static func quoted(_ value: String) -> String {
        var out = ""
        for character in value.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:   out.unicodeScalars.append(character)
            }
        }
        return "\"\(out)\""
    }

    static func unquoted(_ literal: String) -> String? {
        var scalars = Array(literal.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else { return nil }
        scalars = Array(scalars.dropFirst().dropLast())
        var out = ""
        var escaped = false
        for scalar in scalars {
            if escaped {
                switch scalar {
                case "n": out += "\n"
                case "t": out += "\t"
                default:  out.unicodeScalars.append(scalar)
                }
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Поиск секции

    /// Заголовок секции — с кавычками и без: `[mcp_servers.propeller]` пишем мы,
    /// `[mcp_servers."propeller"]` мог написать человек, и это то же самое.
    static func isHeader(_ line: String, of name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "[mcp_servers.\(name)]" || trimmed == "[mcp_servers.\"\(name)\"]"
    }

    /// Любая строка, открывающая таблицу, — граница нашей секции.
    static func opensTable(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    /// Диапазон строк секции: заголовок и всё до следующей таблицы.
    static func range(of name: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { isHeader($0, of: name) }) else { return nil }
        var end = start + 1
        while end < lines.count, !opensTable(lines[end]) { end += 1 }
        return start..<end
    }

    // MARK: - Мёрж

    /// Существующий файл (или его отсутствие) плюс наша запись → новый файл.
    public static func merged(into existing: String?, entry: Entry) throws -> String {
        guard entry.command.hasPrefix("/") else { throw Failure.relativeCommand }
        guard isBareKey(entry.name) else { throw Failure.unsafeName }

        let rendered = render(entry)
        guard let existing, !existing.isEmpty else {
            return rendered.joined(separator: "\n") + "\n"
        }

        var lines = existing.components(separatedBy: "\n")
        // Хвостовой перевод строки даёт пустой последний элемент. Снимаем его на
        // время, чтобы он не считался частью секции, и возвращаем в конце.
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline { lines.removeLast() }

        if let found = range(of: entry.name, in: lines) {
            // Хвостовые пустые строки принадлежат не нам, а промежутку до
            // следующей таблицы: если их проглотить, каждая перезапись будет
            // склеивать секции.
            var tail: [String] = []
            var body = Array(lines[found])
            while body.count > 1, body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                tail.insert(body.removeLast(), at: 0)
            }
            lines.replaceSubrange(found, with: rendered + tail)
        } else {
            if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                lines.append("")
            }
            lines.append(contentsOf: rendered)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Голое имя ключа TOML — то, что можно писать без кавычек.
    static func isBareKey(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains(String($0)) || ("A"..."Z").contains(String($0))
                || ("0"..."9").contains(String($0)) || $0 == "_" || $0 == "-"
        }
    }

    // MARK: - Чтение

    /// Есть ли наша секция с командой, которую есть чем запустить.
    ///
    /// Спрашивается **у файла**, а не у своего сохранённого флага: файл чужой, и
    /// его могли переписать, пока нас не спрашивали.
    public static func contains(_ name: String, in existing: String?) -> Bool {
        guard let value = command(of: name, in: existing) else { return false }
        return !value.isEmpty
    }

    /// Путь к бинарю, на который указывает наша секция, — чтобы отличить
    /// «подключено» от «подключено к тому, чего больше нет».
    public static func command(of name: String, in existing: String?) -> String? {
        guard let existing, !existing.isEmpty else { return nil }
        let lines = existing.components(separatedBy: "\n")
        guard let found = range(of: name, in: lines) else { return nil }
        for line in lines[found].dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command") else { continue }
            let rest = trimmed.dropFirst("command".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let literal = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            return unquoted(literal)
        }
        return nil
    }
}
