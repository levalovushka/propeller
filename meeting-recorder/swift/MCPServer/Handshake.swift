import Foundation
import PropellerPure

/// Отметка о том, что Claude Desktop поднял наш процесс.
///
/// Спросить Клода, видит ли он нас, нельзя ничем: у stdio-сервера нет обратного
/// канала к интерфейсу приложения, а конфиг говорит только о том, что запись в
/// нём есть. Единственный доступный сигнал — что нас запустили; он и есть
/// отметка.
///
/// Это единственная запись, которую делает сервер, и она **вне** архива: в
/// Application Support, рядом с логами. `~/.meeting-recorder` он не трогает.
enum Handshake {

    static var markerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClaudeConnection.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(ClaudeConnection.markerFileName)
    }

    /// Ставится на `initialize` и обновляется на каждом следующем запуске.
    ///
    /// Содержимое — время словами, чтобы файл можно было прочитать глазами;
    /// приложение читает дату изменения файла, потому что она не зависит от
    /// того, что мы туда написали.
    static func mark() {
        let url = markerURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stamp.write(to: url, atomically: true, encoding: .utf8)
    }
}
