import AppKit
import Foundation
import PropellerPure

/// # Кнопка «Подключить» — всё, что она делает
///
/// Находит клиента, бэкапит его конфиг и дописывает в него одну запись. Никаких
/// диалогов: выбирать человеку не из чего, а согласие он уже дал тем, что нажал.
///
/// **Кнопка идемпотентна.** Подключение и переподключение — одно действие:
/// дописать запись, стереть старую отметку, вернуться к ожиданию. Отдельной
/// ветки для потерянного подключения нет и не должно быть — оно отличается от
/// нового только строкой, которую человек прочитал.
///
/// Отметку надо стирать именно здесь: иначе галочка «подключён» встанет по следу
/// трёхдневной давности, и человек решит, что делать больше ничего не надо.
///
/// **Клиентов двое, и весь код общий.** Различия — в `MCPClient`: путь конфига,
/// его формат, имя отметки, заголовок строки. Здесь только файлы и
/// `NSWorkspace`; всё решаемое без диска — в `PropellerPure`
/// (`ClaudeConfigMerge`, `CodexConfigMerge`, `MCPCellMachine`).
@MainActor
enum MCPConnector {

    // MARK: - Где что лежит

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static func configURL(for client: MCPClient) -> URL {
        switch client.configLocation {
        case let .applicationSupport(directory, file):
            return applicationSupport
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(file)
        case let .home(path):
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
        }
    }

    static func markerURL(for client: MCPClient) -> URL {
        applicationSupport
            .appendingPathComponent(ClaudeConnection.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(client.markerFileName)
    }

    /// Журнал вызовов, который дописывает сервер (`ClaudeUsage`). `nonisolated`,
    /// потому что читает его `Analytics`, живущий вне главного актора, а путь —
    /// это знание, а не состояние.
    nonisolated static var usageLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClaudeConnection.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(ClaudeUsage.logFileName)
    }

    /// Бинарь сервера — рядом с нашим собственным исполняемым файлом.
    ///
    /// Выводится из бандла, а не пишется константой: приложение может лежать не
    /// в `/Applications`, и записанный наугад путь дал бы конфиг, указывающий в
    /// пустоту, — то есть «подключено», которое не работает.
    static var serverBinaryURL: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent().appendingPathComponent("PropellerMCP")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Есть ли клиент на машине.
    ///
    /// У ChatGPT ответ шире, чем «стоит ли приложение»: его конфиг общий с Codex
    /// CLI и расширением для IDE, поэтому человек с одним `~/.codex` —
    /// полноправный пользователь фичи, и «Не установлен» сказало бы ему неправду.
    static func isInstalled(_ client: MCPClient) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: client.bundleID) != nil {
            return true
        }
        // Запасной ответ на случай, когда Launch Services ещё не увидел
        // свежепоставленное приложение.
        if FileManager.default.fileExists(atPath: client.applicationPath) { return true }
        guard let marker = client.alternativeHomeMarker else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(marker).path
        )
    }

    // MARK: - Что видно сейчас

    private static func configData(for client: MCPClient) -> Data? {
        try? Data(contentsOf: configURL(for: client))
    }

    private static func configText(for client: MCPClient) -> String? {
        guard let data = configData(for: client) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Путь к бинарю, записанный в чужом конфиге, — или nil, если записи нет.
    private static func recordedCommand(for client: MCPClient) -> String? {
        switch client.configFormat {
        case .json:
            return ClaudeConfigMerge.command(of: ClaudeMCP.serverName, in: configData(for: client))
        case .toml:
            return CodexConfigMerge.command(of: ClaudeMCP.serverName, in: configText(for: client))
        }
    }

    /// Есть ли в конфиге запись, которую клиент может запустить.
    ///
    /// Мало того, что запись есть, — она должна указывать на существующий
    /// бинарь. Человек, перенёсший Propeller из «Программ» или переименовавший
    /// его, оставляет в чужом конфиге путь в пустоту; галочка «подключён» над
    /// таким путём — это ровно то враньё, ради предотвращения которого состояние
    /// вообще выводится из файлов, а не хранится.
    static func isConfigured(_ client: MCPClient) -> Bool {
        guard let command = recordedCommand(for: client) else { return false }
        return FileManager.default.isExecutableFile(atPath: command)
    }

    /// Когда клиент последний раз поднимал наш сервер.
    ///
    /// Читается дата изменения файла, а не то, что в нём написано: сервер пишет
    /// туда время словами для человека, но правда о времени — у файловой
    /// системы, и она не зависит от того, что мы туда положили.
    static func markedAt(_ client: MCPClient) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: markerURL(for: client).path)
        return attributes?[.modificationDate] as? Date
    }

    static func clearMarker(_ client: MCPClient) {
        try? FileManager.default.removeItem(at: markerURL(for: client))
    }

    static func cellState(for client: MCPClient, lastWriteFailed: Bool) -> MCPCellState {
        MCPCellMachine.state(
            installed: isInstalled(client),
            configured: isConfigured(client),
            markedAt: markedAt(client),
            lastWriteFailed: lastWriteFailed
        )
    }

    // MARK: - Нажатие

    enum Refusal: String {
        case noBinary
        case writeDenied
        case unreadableText
    }

    /// Готовое содержимое чужого конфига — или причина, по которой его нет.
    ///
    /// Причина здесь строкой, а не типом: она едет ровно в один параметр
    /// телеметрии, и своя ошибка на каждый формат конфига дала бы два
    /// перечисления, которые всё равно сводятся к строке.
    private enum Prepared {
        case ready(data: Data, existing: Data?, wasConfigured: Bool)
        case refused(reason: String)
    }

    /// Собрать новое содержимое чужого конфига. Ошибка — причина отказа.
    private static func rewritten(
        for client: MCPClient, binary: URL
    ) -> Prepared {
        let existing = configData(for: client)
        switch client.configFormat {
        case .json:
            let entry = ClaudeConfigMerge.Entry(
                name: ClaudeMCP.serverName,
                command: binary.path,
                env: [MCPClient.envKey: client.rawValue]
            )
            let wasConfigured = ClaudeConfigMerge.contains(ClaudeMCP.serverName, in: existing)
            do {
                return .ready(
                    data: try ClaudeConfigMerge.merged(into: existing, entry: entry),
                    existing: existing, wasConfigured: wasConfigured
                )
            } catch let failure as ClaudeConfigMerge.Failure {
                return .refused(reason: failure.rawValue)
            } catch {
                return .refused(reason: "unknown")
            }
        case .toml:
            // Файл есть, но это не текст — трогать нечего: единственный
            // осмысленный ответ на «чужой конфиг в неизвестной кодировке» —
            // не писать в него.
            if let existing, !existing.isEmpty, String(data: existing, encoding: .utf8) == nil {
                return .refused(reason: Refusal.unreadableText.rawValue)
            }
            let text = existing.flatMap { String(data: $0, encoding: .utf8) }
            let entry = CodexConfigMerge.Entry(
                name: ClaudeMCP.serverName,
                command: binary.path,
                env: [MCPClient.envKey: client.rawValue]
            )
            let wasConfigured = CodexConfigMerge.contains(ClaudeMCP.serverName, in: text)
            do {
                let merged = try CodexConfigMerge.merged(into: text, entry: entry)
                guard let data = merged.data(using: .utf8) else {
                    return .refused(reason: ClaudeConfigMerge.Failure.notSerializable.rawValue)
                }
                return .ready(data: data, existing: existing, wasConfigured: wasConfigured)
            } catch let failure as CodexConfigMerge.Failure {
                return .refused(reason: failure.rawValue)
            } catch {
                return .refused(reason: "unknown")
            }
        }
    }

    /// Записать нашу запись в конфиг клиента. `true` — получилось.
    ///
    /// Причина отказа уезжает в телеметрию, а не на экран: разбираемся мы, не
    /// человек. На экране остаётся одна строка и та же кнопка.
    @discardableResult
    static func connect(_ client: MCPClient) -> Bool {
        func failed(_ reason: String) -> Bool {
            Analytics.signal(
                "Claude.connectFailed",
                parameters: ["reason": reason, "client": client.rawValue]
            )
            return false
        }

        guard let binary = serverBinaryURL else { return failed(Refusal.noBinary.rawValue) }

        let data: Data, existing: Data?, wasConfigured: Bool
        switch rewritten(for: client, binary: binary) {
        case let .ready(payload, previous, again):
            data = payload; existing = previous; wasConfigured = again
        case let .refused(reason):
            return failed(reason)
        }

        let url = configURL(for: client)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Копия рядом — до записи. Файл чужой, и вернуть его должно быть
            // возможно без нас.
            if let existing, !existing.isEmpty {
                try? existing.write(to: url.appendingPathExtension("bak"), options: .atomic)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            return failed(Refusal.writeDenied.rawValue)
        }

        // Старый след стирается вместе с записью: галочка обязана означать
        // «этот клиент нас видел», а не «когда-то видел какой-то».
        clearMarker(client)
        Analytics.signal(
            "Claude.connected",
            parameters: ["again": wasConfigured ? "1" : "0", "client": client.rawValue]
        )
        return true
    }
}

extension MCPConnector {

    /// Кому предлагаем подключиться в рельсе.
    ///
    /// Порядок `MCPClient.allCases` — порядок предпочтения: стоят оба, спросим
    /// про Клода. Ни одного нет — вопроса тоже нет, иначе подошва рельса стала
    /// бы рекламой чужого приложения.
    static var clientToOffer: MCPClient? {
        MCPClient.allCases.first(where: isInstalled)
    }
}
