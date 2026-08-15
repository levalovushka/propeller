import Foundation

/// # Сколько людей действительно спрашивают Клода о встречах
///
/// Отметка о запуске на этот вопрос не отвечает и никогда не ответит:
/// stdio-серверы поднимаются вместе с Claude Desktop, поэтому она означает
/// «Клод нас видит». Человек, который подключил и ни разу не спросил, и человек,
/// который спрашивает каждый день, дают одну и ту же отметку.
///
/// Считать поэтому приходится вызовы инструментов, а они случаются в чужом
/// процессе. Устройство: **сервер дописывает строку, приложение отправляет и
/// стирает**. Так у сервера не появляется ни сети, ни SDK, ни очереди отправки
/// в процессе, которым владеет не он, а сигнал уезжает тем же путём, что и все
/// остальные, — с той же конфигурацией в параметрах.
///
/// Журнал — по строке на вызов, а не счётчик в JSON, и это не стиль: серверов
/// может быть **два сразу** (Claude Desktop и Claude Code поднимают свои), а
/// «прочитать, прибавить, записать» из двух процессов теряет вызовы. Дописать
/// строку в конец — нет.
public enum ClaudeUsage {

    /// Рядом с отметкой, в Application Support. В архив по-прежнему не пишем
    /// ничего.
    public static let logFileName = "claude-usage.log"

    /// Одна строка журнала: день и инструмент. Ни идентификаторов встреч, ни
    /// запросов, ни единого слова из архива — здесь нечему утечь.
    public static func line(day: String, tool: String) -> String {
        "\(day)\t\(tool)"
    }

    /// День в том виде, в каком он попадает в журнал.
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: timeZone, formatOptions: [.withFullDate])
    }

    /// Сводка журнала: сколько раз какой инструмент звали.
    ///
    /// Дни в сводке не различаются намеренно. Вопрос, на который она отвечает, —
    /// «пользуются ли», и его закрывает частота вызовов у одного человека;
    /// раскладка по дням стоила бы сигнала на каждый день и не сказала бы
    /// ничего сверх этого.
    public struct Summary: Equatable, Sendable {
        /// Инструмент → сколько раз позвали.
        public let calls: [String: Int]
        /// Сколько разных дней в журнале есть хоть один вызов.
        public let activeDays: Int

        public var total: Int { calls.values.reduce(0, +) }
        public var isEmpty: Bool { calls.isEmpty }
    }

    /// Разбор журнала. Битая строка пропускается: журнал пишет другой процесс,
    /// его могли оборвать на середине строки убийством, и терять из-за этого
    /// весь замер незачем.
    public static func summarize(_ log: String) -> Summary {
        var calls: [String: Int] = [:]
        var days = Set<String>()
        for raw in log.split(separator: "\n") {
            let parts = raw.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let day = String(parts[0]), tool = String(parts[1])
            guard !day.isEmpty, !tool.isEmpty else { continue }
            // Имя инструмента уезжает в параметр сигнала — принимаем только те,
            // что мы сами объявили. Иначе строка, дописанная чем угодно, стала
            // бы значением в аналитике.
            guard ClaudeMCP.tools.contains(where: { $0.name == tool }) else { continue }
            calls[tool, default: 0] += 1
            days.insert(day)
        }
        return Summary(calls: calls, activeDays: days.count)
    }

    /// Бакет частоты — то, чем один человек отличается от другого в отчёте.
    /// Само число вызовов уезжает отдельно, значением сигнала.
    public static func frequencyBucket(_ total: Int) -> String {
        switch total {
        case ..<1:  return "0"
        case 1:     return "1"
        case 2...5: return "2-5"
        case 6...20: return "6-20"
        default:    return "20+"
        }
    }
}
