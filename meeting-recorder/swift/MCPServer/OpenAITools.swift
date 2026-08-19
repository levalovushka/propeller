import Foundation
import PropellerPure

/// # `search` и `fetch` — чужой контракт, наши встречи
///
/// ChatGPT в путях deep research и company knowledge зовёт только два имени и
/// ждёт от них строго определённой формы: у `search` — единственный строковый
/// параметр и список `{id, title, url}`, у `fetch` — `id` и полный текст. Форма
/// проверена по документации OpenAI, а не по памяти.
///
/// Две особенности, из-за которых это отдельный файл, а не ветка в `Tools`:
///
/// **Ответ идёт дважды.** Кроме обычного `content` с текстом требуется
/// `structuredContent` тем же содержимым в виде объекта. Одно без другого —
/// половина контракта.
///
/// **Сноска живёт на `url`.** ChatGPT делает ссылку на источник только там, где
/// `url` непустой, поэтому в него кладётся `file://` до файла встречи. Файла
/// может не быть — тогда поле пустое, и это честнее выдуманного адреса.
enum OpenAITools {

    /// Текст для `content` и объект для `structuredContent` — одно и то же.
    struct Answer {
        let structured: [String: Any]

        var text: String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]
            ), let string = String(data: data, encoding: .utf8) else { return "{}" }
            return string
        }
    }

    static func handles(_ name: String) -> Bool {
        name == ClaudeMCP.searchDocuments || name == ClaudeMCP.fetchDocument
    }

    static func call(name: String, arguments: [String: Any]) throws -> Answer {
        switch name {
        case ClaudeMCP.searchDocuments: return search(arguments)
        case ClaudeMCP.fetchDocument:   return try fetch(arguments)
        default: throw Tools.Failure(message: "Неизвестный инструмент: \(name)")
        }
    }

    // MARK: - search

    private static func search(_ arguments: [String: Any]) -> Answer {
        let query = (arguments["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pairs = Archive.cards()
        let found = MeetingLookup.run(
            cards: pairs.map(\.card),
            filter: MeetingLookup.Filter(query: query, from: nil, to: nil, people: [])
        )
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Archive.meetingsPath)) ?? []

        let results: [[String: Any]] = found.map { result in
            let card = result.card
            return [
                "id": card.id,
                // Заголовок с датой: в списке сносок «Стратегия студии» без числа
                // неотличима от такой же встречи месяцем раньше.
                "title": "\(card.title) — \(card.dateLabel)",
                "url": Archive.fileURL(for: card.id, in: files)?.absoluteString ?? "",
            ]
        }
        return Answer(structured: ["results": results])
    }

    // MARK: - fetch

    private static func fetch(_ arguments: [String: Any]) throws -> Answer {
        let id = (arguments["id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            throw Tools.Failure(message: "Нужен id встречи — его отдаёт search.")
        }
        guard let entry = Archive.entry(id: id) else {
            throw Tools.Failure(message: "Встречи \(id) в архиве нет. Найдите её через search.")
        }

        // Конспект, а если его нет — расшифровка. Пустой встречи здесь не
        // бывает: та, у которой нет ни того ни другого, не попадает и в search.
        let body = Archive.recap(for: id)
            ?? (try? Tools.call(name: ClaudeMCP.getTranscript, arguments: ["id": id, "full": true]))
            ?? "Ни саммари, ни расшифровки у этой встречи нет."

        var metadata: [String: String] = ["date": Archive.dateLabel(entry.date)]
        if let topics = entry.topics, !topics.isEmpty {
            metadata["topics"] = topics.joined(separator: ", ")
        }
        let invited = Archive.invited(of: entry)
        if !invited.isEmpty { metadata["invited"] = invited.joined(separator: ", ") }

        return Answer(structured: [
            "id": id,
            "title": entry.title,
            "text": body,
            "url": Archive.fileURL(for: id)?.absoluteString ?? "",
            "metadata": metadata,
        ])
    }
}
