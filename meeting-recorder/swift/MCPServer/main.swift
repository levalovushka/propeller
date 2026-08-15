import Foundation
import PropellerPure

/// # Propeller как MCP-сервер для Claude Desktop
///
/// Отдельный бинарь внутри `Propeller.app`, а не режим приложения. Причин три,
/// и все три — про то, что процессом владеет не Пропеллер: сервер поднимает
/// Claude Desktop на своём старте, он обязан работать при закрытом Пропеллере,
/// и он не должен зависеть от того, что приложение сейчас делает с индексом.
/// Путь к бинарю при этом стабилен — Sparkle обновляет бандл целиком, так что
/// запись в конфиге Клода не протухает.
///
/// Транспорт — stdio, построчный JSON-RPC 2.0. Отсюда правило, которое ломает
/// такие серверы чаще всего: **в stdout не летит ничего, кроме сообщений
/// протокола**. Любой отладочный вывод — в stderr, иначе клиент видит мусор
/// вместо ответа и молча закрывает соединение.
///
/// Только чтение. Единственная запись за весь жизненный цикл — отметка о
/// запуске (`Handshake`), и она в Application Support, а не в архиве.

// MARK: - Ответы

private func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: []),
          var line = String(data: data, encoding: .utf8) else { return }
    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
}

private func reply(id: Any, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
}

private func reply(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}

// MARK: - Версия

/// Версия берётся из Info.plist бандла, внутри которого лежит бинарь: он живёт
/// в `Propeller.app/Contents/MacOS/`, и версия приложения — единственная, про
/// которую здесь можно не соврать.
private func serverVersion() -> String {
    let plist = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()      // MacOS
        .deletingLastPathComponent()      // Contents
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let version = parsed["CFBundleShortVersionString"] as? String else { return "0" }
    return version
}

// MARK: - Разбор запроса

private func handle(_ message: [String: Any]) -> [String: Any]? {
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]
    // Уведомление — сообщение без `id`. На него не отвечают вовсе, и ответ на
    // него клиент считает ошибкой протокола.
    let id = message["id"]

    switch method {
    case "initialize":
        // Отметка ставится здесь: это первое, что говорит клиент, и
        // единственный момент, в который мы точно знаем, что нас запустил он.
        Handshake.mark()
        guard let id else { return nil }
        return reply(id: id, result: [
            "protocolVersion": ClaudeMCP.negotiatedProtocol(
                requested: params["protocolVersion"] as? String
            ),
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": ClaudeMCP.serverName, "version": serverVersion()],
            "instructions": ClaudeMCP.instructions,
        ])

    case "notifications/initialized":
        Handshake.mark()
        return nil

    case _ where method.hasPrefix("notifications/"):
        return nil

    case "ping":
        guard let id else { return nil }
        return reply(id: id, result: [:])

    case "tools/list":
        guard let id else { return nil }
        guard let data = try? JSONEncoder().encode(ClaudeMCP.tools),
              let tools = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return reply(id: id, code: -32603, message: "Не удалось собрать список инструментов")
        }
        return reply(id: id, result: ["tools": tools])

    case "tools/call":
        guard let id else { return nil }
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard ClaudeMCP.tool(named: name) != nil else {
            return reply(id: id, code: -32602, message: "Неизвестный инструмент: \(name)")
        }
        do {
            let text = try Tools.call(name: name, arguments: arguments)
            return reply(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        } catch let failure as Tools.Failure {
            // Ошибка инструмента — это результат, а не ошибка протокола: модель
            // должна прочитать причину и попробовать иначе, а не увидеть обрыв.
            return reply(id: id, result: [
                "content": [["type": "text", "text": failure.message]],
                "isError": true,
            ])
        } catch {
            return reply(id: id, result: [
                "content": [["type": "text", "text": "Не получилось прочитать архив: \(error.localizedDescription)"]],
                "isError": true,
            ])
        }

    default:
        guard let id else { return nil }
        return reply(id: id, code: -32601, message: "Метод не поддерживается: \(method)")
    }
}

// MARK: - Цикл

/// `--paths` — единственный ответ на вопрос «а тот ли архив он читает».
///
/// Пути приезжают из настроек приложения, и разойтись они могут молча: сервер
/// прочитает пустой каталог и честно скажет «встреч нет», а человек будет
/// смотреть на полный архив. Наблюдать это иначе нечем — у процесса, которым
/// владеет Клод, нет ни окна, ни лога, который кто-то откроет.
if CommandLine.arguments.contains("--paths") {
    print("recordings: \(Archive.recordingsPath)")
    print("meetings:   \(Archive.meetingsPath)")
    print("index:      \(Archive.indexURL.path)")
    print("встреч:     \(Archive.entries().count)")
    print("отметка:    \(Handshake.markerURL.path)")
    exit(0)
}

/// Пул на каждое сообщение — не гигиена, а условие жизни.
///
/// Процесс живёт столько же, сколько открыт Claude Desktop, то есть днями, а
/// весь разбор идёт через Foundation: `JSONSerialization`, `FileManager`,
/// `NSRegularExpression`. Всё это отдаёт объекты в пул, а у цикла верхнего
/// уровня пул один и не сливается никогда. Замерено на этой машине: без пула
/// RSS рос ровно на 0,2 МБ за вызов и через триста вызовов доходил до 87 МБ,
/// не выходя на плато.
while let line = readLine(strippingNewline: true) {
    autoreleasepool {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(),
                  "error": ["code": -32700, "message": "Сообщение не разобралось как JSON"]])
            return
        }
        if let answer = handle(message) { send(answer) }
    }
}
