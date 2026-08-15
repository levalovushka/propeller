import Foundation
import PropellerPure

/// Что именно отвечают четыре инструмента.
///
/// Ответ — текст, а не JSON: его читает модель, и связная строка «14 августа,
/// „Стратегия студии“, решили то-то» стоит ей дешевле, чем разбор объекта с
/// восемью полями. Правила отбора при этом здесь не живут — они в
/// `PropellerPure` (`MeetingLookup`, `RecapDigest`, `TranscriptSlice`), где до
/// них дотягивается тест.
enum Tools {

    struct Failure: Error {
        let message: String
    }

    static func call(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case ClaudeMCP.searchMeetings:    return searchMeetings(arguments)
        case ClaudeMCP.getRecap:          return try getRecap(arguments)
        case ClaudeMCP.findDecisions:
            return harvest(arguments, section: RecapDigest.decisionsTitle, noun: "Решения")
        case ClaudeMCP.findOpenQuestions:
            return harvest(arguments, section: RecapDigest.openQuestionsTitle, noun: "Открытые вопросы")
        case ClaudeMCP.getTranscript:     return try getTranscript(arguments)
        default:
            throw Failure(message: "Неизвестный инструмент: \(name)")
        }
    }

    // MARK: - Аргументы

    private static func string(_ arguments: [String: Any], _ key: String) -> String {
        (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func strings(_ arguments: [String: Any], _ key: String) -> [String] {
        if let list = arguments[key] as? [String] { return list }
        if let single = arguments[key] as? String, !single.isEmpty { return [single] }
        return []
    }

    private static func flag(_ arguments: [String: Any], _ key: String) -> Bool {
        if let value = arguments[key] as? Bool { return value }
        if let value = arguments[key] as? NSNumber { return value.boolValue }
        if let value = arguments[key] as? String { return value == "true" || value == "1" }
        return false
    }

    // MARK: - search_meetings

    private static func searchMeetings(_ arguments: [String: Any]) -> String {
        let pairs = Archive.cards()
        let filter = MeetingLookup.Filter(
            query: string(arguments, "query"),
            from: MeetingLookup.day(arguments["from"] as? String),
            to: MeetingLookup.endOfDay(arguments["to"] as? String),
            people: strings(arguments, "people")
        )
        let found = MeetingLookup.run(cards: pairs.map(\.card), filter: filter)

        guard !found.isEmpty else {
            return pairs.isEmpty
                ? "Архив Propeller пуст: записанных встреч нет."
                : "Ничего не нашлось. Всего встреч в архиве: \(pairs.count). Попробуйте другие слова или снимите ограничение по датам."
        }

        var lines = ["Встреч в ответе: \(found.count). Всего в архиве: \(pairs.count).", ""]
        for result in found {
            let card = result.card
            var head = "\(card.id) · \(card.dateLabel)"
            if card.durationSeconds > 0 { head += " · \(duration(card.durationSeconds))" }
            lines.append(head)
            lines.append("Заголовок: \(card.title)")
            if !card.topics.isEmpty { lines.append("Темы: \(card.topics.joined(separator: ", "))") }
            if !card.tags.isEmpty { lines.append("Теги: \(card.tags.joined(separator: ", "))") }
            if !card.people.isEmpty { lines.append("Говорили: \(card.people.joined(separator: ", "))") }
            if !card.invited.isEmpty { lines.append("Звали: \(card.invited.joined(separator: ", "))") }
            if let snippet = result.snippet {
                lines.append("Фрагмент: \(snippet.prefix)\(snippet.match)\(snippet.suffix)")
            }
            lines.append("")
        }
        lines.append("Дальше: get_recap(id) — саммари встречи целиком; get_transcript(id, query) — дословные реплики.")
        return lines.joined(separator: "\n")
    }

    // MARK: - get_recap

    private static func getRecap(_ arguments: [String: Any]) throws -> String {
        let id = string(arguments, "id")
        guard !id.isEmpty else { throw Failure(message: "Нужен id встречи — его отдаёт search_meetings.") }
        guard let entry = Archive.entry(id: id) else {
            throw Failure(message: "Встречи \(id) в архиве нет. Найдите её через search_meetings.")
        }

        var lines = [header(entry)]
        let people = Set(Archive.segments(of: entry).map(\.speaker)).sorted()
        if !people.isEmpty { lines.append("Говорили: \(people.joined(separator: ", "))") }
        let invited = Archive.invited(of: entry)
        if !invited.isEmpty { lines.append("Звали: \(invited.joined(separator: ", "))") }
        if let topics = entry.topics, !topics.isEmpty {
            lines.append("Темы: \(topics.joined(separator: ", "))")
        }
        lines.append("")

        guard let recap = Archive.recap(for: id), !recap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let hasText = (entry.transcript?.isEmpty == false) || !Archive.segments(of: entry).isEmpty
            lines.append(hasText
                ? "Саммари этой встречи ещё нет — расшифровка есть: get_transcript(\"\(id)\")."
                : "Саммари этой встречи нет, расшифровки тоже.")
            return lines.joined(separator: "\n")
        }
        lines.append(withoutDocumentTitle(recap))
        return lines.joined(separator: "\n")
    }

    // MARK: - find_decisions / find_open_questions

    private static func harvest(_ arguments: [String: Any], section: String, noun: String) -> String {
        let topic = string(arguments, "topic")
        let from = MeetingLookup.day(arguments["from"] as? String)
        let to = MeetingLookup.endOfDay(arguments["to"] as? String)

        let meetings = Archive.cards()
            .filter { pair in
                if let from, pair.card.date < from { return false }
                if let to, pair.card.date > to { return false }
                return pair.recap != nil
            }
            .map { (card: $0.card, digest: RecapDigest.parse($0.recap ?? "")) }

        let items = MeetingLookup.harvest(section: section, from: meetings, topic: topic)
        guard !items.isEmpty else {
            let where_ = topic.isEmpty ? "в архиве" : "по теме «\(topic)»"
            // «Просмотрено», а не «всего»: под фильтром по датам это число —
            // размер выборки, и назвать его размером архива значит подсказать
            // модели уверенно неверный итог.
            return "\(noun) \(where_) не нашлись. Просмотрено встреч с саммари: \(meetings.count)."
        }

        let scope = topic.isEmpty ? "" : " по теме «\(topic)»"
        let meetingCount = Set(items.map(\.meetingID)).count
        var lines = ["\(noun)\(scope): \(items.count). Встреч, из которых они собраны: \(meetingCount).", ""]
        for item in items {
            var origin = "\(item.meetingTitle) · \(Archive.dateLabel(item.date)) · \(item.meetingID)"
            if let timecode = item.timecode { origin += " · \(timecode)" }
            lines.append("- \(item.text)")
            lines.append("  \(origin)")
        }
        lines.append("")
        lines.append("Подробности встречи: get_recap(id).")
        return lines.joined(separator: "\n")
    }

    // MARK: - get_transcript

    private static func getTranscript(_ arguments: [String: Any]) throws -> String {
        let id = string(arguments, "id")
        guard !id.isEmpty else { throw Failure(message: "Нужен id встречи — его отдаёт search_meetings.") }
        guard let entry = Archive.entry(id: id) else {
            throw Failure(message: "Встречи \(id) в архиве нет. Найдите её через search_meetings.")
        }
        let segments = Archive.segments(of: entry)
        guard !segments.isEmpty else {
            let plain = entry.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if plain.isEmpty {
                return "\(header(entry))\n\nРасшифровки этой встречи нет."
            }
            // Старые встречи без размеченных реплик: отдаём текст, но честно
            // говорим, что резать его по говорящему и таймкоду нечем.
            return "\(header(entry))\n\nРазмеченных реплик нет — только сплошной текст.\n\n\(plain)"
        }

        let around = RecapDigest.seconds(fromTimecode: string(arguments, "around"))
        let request = TranscriptSlice.Request(
            query: string(arguments, "query"),
            speaker: string(arguments, "speaker"),
            around: around,
            full: flag(arguments, "full")
        )
        let slice = TranscriptSlice.run(segments: segments, request: request)
        guard !slice.isEmpty else {
            return "\(header(entry))\n\nВ расшифровке ничего не нашлось по этому запросу. Всего реплик: \(segments.count)."
        }
        var lines = [header(entry)]
        if request.isBlank {
            lines.append("Начало встречи; дальше — get_transcript с query, speaker или around.")
        }
        lines.append("")
        lines.append(TranscriptSlice.render(slice))
        return lines.joined(separator: "\n")
    }

    // MARK: - Общее

    /// Снимаем заголовок документа («# Запись 14.08.2026 — рекап»): шапку мы
    /// уже написали сами, и она честнее — файл назван слагом того заголовка,
    /// который стоял в момент записи, а встречу с тех пор могли переименовать.
    private static func withoutDocumentTitle(_ recap: String) -> String {
        var lines = recap.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first, first.hasPrefix("# ") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func header(_ entry: Archive.Entry) -> String {
        var head = "\(entry.title) · \(Archive.dateLabel(entry.date)) · \(entry.id)"
        if entry.duration > 0 { head += " · \(duration(entry.duration))" }
        return head
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) ч \(minutes) мин" }
        if minutes > 0 { return "\(minutes) мин" }
        return "\(total) с"
    }

}
