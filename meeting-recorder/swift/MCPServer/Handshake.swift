import Foundation
import PropellerPure

/// Отметка о том, что клиент поднял наш процесс.
///
/// Спросить клиента, видит ли он нас, нельзя ничем: у stdio-сервера нет
/// обратного канала к интерфейсу приложения, а конфиг говорит только о том, что
/// запись в нём есть. Единственный доступный сигнал — что нас запустили; он и
/// есть отметка.
///
/// **Отметка у каждого клиента своя.** Одна на двоих зажигала бы галочку у того,
/// кого не подключали: Claude Desktop и ChatGPT поднимают по своему процессу
/// нашего сервера, и «кто-то нас запустил» — не ответ на вопрос «кто».
///
/// Это единственная запись, которую делает сервер, и она **вне** архива: в
/// Application Support, рядом с логами. `~/.meeting-recorder` он не трогает.
enum Handshake {

    /// Кто нас запустил. Выясняется на `initialize` и живёт до конца процесса —
    /// процесс поднят одним клиентом и другому не достаётся.
    private(set) static var client: MCPClient?

    /// Подпись из окружения нашей же записи в чужом конфиге. Точнее, чем
    /// `clientInfo`: её написали мы, когда подключали.
    static func adopt(clientName: String?) {
        client = MCPClient.resolve(
            env: ProcessInfo.processInfo.environment, clientName: clientName
        )
    }

    static func markerURL(for client: MCPClient) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClaudeConnection.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(client.markerFileName)
    }

    /// Ставится на `initialize` и обновляется на каждом следующем запуске.
    ///
    /// Содержимое — время словами, чтобы файл можно было прочитать глазами;
    /// приложение читает дату изменения файла, потому что она не зависит от
    /// того, что мы туда написали.
    ///
    /// Клиента опознать не удалось — не пишем ничего. Отметка означает «вот
    /// этот клиент нас видел»; поставленная наугад, она зажгла бы галочку не у
    /// того, а «никто не подключён» — состояние честное и поправимое кнопкой.
    static func mark() {
        guard let client else { return }
        let url = markerURL(for: client)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stamp.write(to: url, atomically: true, encoding: .utf8)
    }
}
