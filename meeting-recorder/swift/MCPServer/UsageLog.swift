import Foundation
import PropellerPure

/// Дописать строку про состоявшийся вызов.
///
/// Вторая и последняя запись, которую делает сервер, и снова вне архива —
/// в Application Support, рядом с отметкой.
///
/// **Дописывание, а не перезапись.** Claude Desktop и Claude Code поднимают
/// каждый свой процесс, и они пишут в один файл одновременно; строка короче
/// буфера в режиме `O_APPEND` доезжает целиком, а «прочитал, прибавил,
/// записал» из двух процессов теряет вызовы молча.
enum UsageLog {

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClaudeConnection.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(ClaudeUsage.logFileName)
    }

    /// Выключенная телеметрия означает, что счёт не ведётся вовсе, а не что он
    /// ведётся и не отправляется. Настройка читается из домена приложения — та
    /// же, что человек видит переключателем в настройках.
    private static var allowed: Bool {
        Archive.analyticsEnabled
    }

    static func record(tool: String) {
        guard allowed else { return }
        let line = ClaudeUsage.line(day: ClaudeUsage.day(Date()), tool: tool) + "\n"
        guard let data = line.data(using: .utf8) else { return }

        let target = url
        let manager = FileManager.default
        try? manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: target.path) {
            try? data.write(to: target, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: target) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
