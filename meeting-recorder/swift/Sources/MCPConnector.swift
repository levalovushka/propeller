import AppKit
import Foundation
import PropellerPure

/// # Кнопка «Подключить» — всё, что она делает
///
/// Находит Claude Desktop, бэкапит его конфиг и дописывает в него одну запись.
/// Никаких диалогов: выбирать человеку не из чего, а согласие он уже дал тем,
/// что нажал.
///
/// **Кнопка идемпотентна.** Подключение и переподключение — одно действие:
/// дописать запись, стереть старую отметку, вернуться к «Перезапустите Claude».
/// Отдельной ветки для потерянного подключения нет и не должно быть — оно
/// отличается от нового только строкой, которую человек прочитал.
///
/// Отметку надо стирать именно здесь: иначе галочка «подключён» встанет по
/// следу трёхдневной давности, и человек решит, что перезапускать Клода не
/// надо.
///
/// Всё, что решаемо без диска, — в `PropellerPure` (`ClaudeConfigMerge`,
/// `ClaudeCellMachine`). Здесь только файлы и `NSWorkspace`.
@MainActor
enum ClaudeConnector {

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    // MARK: - Где что лежит

    static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClaudeConnection.configDirectoryName, isDirectory: true)
            .appendingPathComponent(ClaudeConnection.configFileName)
    }

    /// Журнал вызовов, который дописывает сервер (`ClaudeUsage`). `nonisolated`,
    /// потому что читает его `Analytics`, живущий вне главного актора, а путь —
    /// это знание, а не состояние.
    nonisolated static var usageLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClaudeConnection.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(ClaudeUsage.logFileName)
    }

    static var markerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClaudeConnection.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(ClaudeConnection.markerFileName)
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

    static var isClaudeInstalled: Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) != nil { return true }
        // Запасной ответ на случай, когда Launch Services ещё не увидел
        // свежепоставленное приложение.
        return FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    }

    // MARK: - Что видно сейчас

    private static var configData: Data? {
        try? Data(contentsOf: configURL)
    }

    /// Есть ли в конфиге запись, которую Клод может запустить.
    ///
    /// Мало того, что запись есть, — она должна указывать на существующий
    /// бинарь. Человек, перенёсший Propeller из «Программ» или переименовавший
    /// его, оставляет в чужом конфиге путь в пустоту; галочка «Claude
    /// подключён» над таким путём — это ровно то враньё, ради предотвращения
    /// которого состояние вообще выводится из файлов, а не хранится. Ответ
    /// «нет» здесь даёт «Подключение потерялось» и кнопку, которая перепишет
    /// путь на нынешний.
    static var isConfigured: Bool {
        guard let command = ClaudeConfigMerge.command(of: ClaudeMCP.serverName, in: configData) else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: command)
    }

    /// Когда Claude Desktop последний раз поднимал наш сервер.
    ///
    /// Читается дата изменения файла, а не то, что в нём написано: сервер пишет
    /// туда время словами для человека, но правда о времени — у файловой
    /// системы, и она не зависит от того, что мы туда положили.
    static var markedAt: Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: markerURL.path)
        return attributes?[.modificationDate] as? Date
    }

    static func clearMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    static func cellState(lastWriteFailed: Bool) -> ClaudeCellState {
        ClaudeCellMachine.state(
            claudeInstalled: isClaudeInstalled,
            configured: isConfigured,
            markedAt: markedAt,
            lastWriteFailed: lastWriteFailed
        )
    }

    // MARK: - Нажатие

    enum Refusal: String {
        case noBinary
        case writeDenied
    }

    /// Записать нашу запись в конфиг Клода. `true` — получилось.
    ///
    /// Причина отказа уезжает в телеметрию, а не на экран: разбираемся мы, не
    /// человек. На экране остаётся одна строка и та же кнопка.
    @discardableResult
    static func connect() -> Bool {
        guard let binary = serverBinaryURL else {
            Analytics.signal("Claude.connectFailed", parameters: ["reason": Refusal.noBinary.rawValue])
            return false
        }
        let entry = ClaudeConfigMerge.Entry(name: ClaudeMCP.serverName, command: binary.path)
        let existing = configData
        let wasConfigured = ClaudeConfigMerge.contains(ClaudeMCP.serverName, in: existing)

        let merged: Data
        do {
            merged = try ClaudeConfigMerge.merged(into: existing, entry: entry)
        } catch let failure as ClaudeConfigMerge.Failure {
            Analytics.signal("Claude.connectFailed", parameters: ["reason": failure.rawValue])
            return false
        } catch {
            Analytics.signal("Claude.connectFailed", parameters: ["reason": "unknown"])
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Копия рядом — до записи. Файл чужой, и вернуть его должно быть
            // возможно без нас.
            if let existing, !existing.isEmpty {
                let backup = configURL.appendingPathExtension("bak")
                try? existing.write(to: backup, options: .atomic)
            }
            try merged.write(to: configURL, options: .atomic)
        } catch {
            Analytics.signal("Claude.connectFailed", parameters: ["reason": Refusal.writeDenied.rawValue])
            return false
        }

        // Старый след стирается вместе с записью: галочка обязана означать
        // «этот Клод нас видел», а не «когда-то видел какой-то».
        clearMarker()
        Analytics.signal("Claude.connected", parameters: ["again": wasConfigured ? "1" : "0"])
        return true
    }
}
