import Foundation

/// Что не так с готовым конспектом — без модели, без сети и без мнения.
///
/// Это не проверка «на всякий случай», а половина второго прохода. Замер
/// (`tools/recap-lab`, 8 встреч) показал, что редактор-модель исполняет правило,
/// к которому приложена цитата, и пропускает то же правило девятым в списке:
/// общая редактура убрала 21 находку из 153, адресная — 49. Поэтому здесь
/// каждая находка носит с собой кусок текста, по которому её видно.
///
/// Каждая проверка попала сюда, потому что сработала на реальном архиве. Правил
/// «на будущее» тут нет: линтер, зелёный на сломанном тексте, ничему не учит.
public enum RecapLint {

    public enum Kind: String, CaseIterable {
        /// Срок, которого никто не называл. Самая опасная выдумка: отличить её
        /// от правды через неделю уже нельзя.
        case unspokenDeadline
        /// «**Система**», «участник с ответственностью» — читается как
        /// назначение и не называет никого.
        case ghostOwner
        /// «Сторонники согласились» — подлежащее, которого на встрече не было.
        case inventedActor
        /// «Проведите очистку». Конспект рассказывает, что было, а не раздаёт
        /// указания; появилось, когда редактору дали инструкции в приказном
        /// тоне, и он перенёс тон в документ.
        case imperative
        /// «(срок: ~6 дней)» — арифметика вместо того, что прозвучало.
        case computedDeadline
        case passive
        case clerical
        case filler
        case longSentence
    }

    public struct Finding: Equatable {
        public let kind: Kind
        /// То, по чему находку видно в тексте: цитата или число слов.
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Предложение длиннее — это две мысли, слипшиеся в одну. Медиана по архиву
    /// 18,4 слова, проблема в хвосте.
    public static let maxSentenceWords = 22

    /// Больше редактор всё равно не удержит: замерено на четырёхмиллиардной
    /// модели, дальше по списку исполнение падает.
    public static let maxNotes = 20

    // MARK: - Словари

    private static let passive = [
        #"\bбыл[оаи]?\s+(?:решен|принят|достигнут|согласован|утверждён|утвержден)\w*"#,
        #"\b(?:обсуждал|рассматривал|планировал|отмечал|подчёркивал|подчеркивал)\w*с[яь]\b"#,
        #"\b(?:решено|принято|утверждено|согласовано|достигнуто|отмечено|выявлено|зафиксировано|предложено|определено)\b"#,
    ]

    private static let clerical = [
        #"\bв рамках\b"#, #"\bв целях\b"#, #"\bс целью\b"#, #"\bпосредством\b"#, #"\bпутём\b"#,
        // «данные» и «данных» — это data, обычное слово; канцелярит — «данный вопрос».
        #"\bданн(?:ый|ая|ое|ого|ой|ом|ому)\b"#, #"\bявляет\w*\b"#, #"\bосуществля\w+\b"#,
        #"\bнеобходимо отметить\b"#, #"\bследует отметить\b"#, #"\bв части\b"#,
        #"\bпо итогам обсуждения\b"#, #"\bв ходе обсуждения\b"#, #"\bреализац\w+\b"#,
    ]

    private static let filler = [
        #"\bследующие шаги\b"#, #"\bприоритеты\b"#, #"\bключев\w+\b"#,
        #"\bсоответствующ\w+\b"#, #"\bопределённ\w+\b"#,
    ]

    /// Выдуманное действующее лицо: «Сторонники согласились», «Стороны решили».
    ///
    /// Порождено правилом «пассив → глагол с действующим лицом»: редактору
    /// сказали найти подлежащее, и там, где его не было, он его сочинил. На
    /// встрече не было никаких «сторонников» — было двое людей с именами.
    /// Ловится только в связке с глаголом договорённости: «участники» само по
    /// себе — обычное слово.
    private static let inventedActor =
        #"\b(Сторонник\w*|Сторон[ыа]|Участники|Коллеги|Команда|Стейкхолдер\w*)\s+(?:соглас\w+|отказ\w+|реши\w+|договор\w+|подтверд\w+|дообуч\w+|переда\w+|определи\w+)"#

    /// Срок, посчитанный в днях или неделях. На встрече говорят «к пятнице» или
    /// «сегодня к шести»; «~6 дней» и «в течение 2 недель» — это арифметика
    /// модели поверх того, чего она не знает.
    private static let computedDeadline =
        #"срок:?\s*~?\s*\d+\s*(?:дн|недел|месяц)\w*|в течение\s+\d+\s*(?:дн|недел|месяц)\w*"#

    /// Два паттерна, а не один с `|`: цитата берётся из группы, а у альтернатив
    /// верхнего уровня своей группы нет — половина находок молча терялась.
    private static let ghostOwner = [
        // Псевдо-ответственный имеет смысл только в начале пункта: «команда» в
        // середине фразы — обычное слово.
        #"(?m)^\s*-\s*\*{0,2}(Система|Команда|Участник|Все|Разработка)\b"#,
        #"(неявный ответственн\w*|участник с ответственностью|или участник)"#,
    ]

    private static let imperative =
        #"(?m)(?:^\s*-\s*|^|—\s+|:\s+)\*{0,2}([А-ЯЁа-яё]{4,}(?:йте|ьте|ните|шите|дите))\b"#

    /// Срок → корень, который обязан найтись в транскрипте. «К пятнице» — ложь,
    /// если про пятницу никто не говорил вслух.
    private static let deadlines: [(phrase: String, stem: String)] = [
        (#"понедельник"#, "понедельник"), (#"вторник"#, "вторник"), (#"сред[уые]\b"#, "сред"),
        (#"четверг"#, "четверг"), (#"пятниц"#, "пятниц"), (#"суббот"#, "суббот"),
        (#"воскресен"#, "воскресен"), (#"завтра"#, "завтра"), (#"послезавтра"#, "послезавтра"),
        (#"до конца недели"#, "недел"), (#"в течение недели"#, "недел"),
        (#"на следующей неделе"#, "недел"), (#"следующей рабочей недел"#, "недел"),
        (#"до конца дня"#, "конца дня"), (#"в течение дня"#, "течение дня"),
        (#"к концу дня"#, "конца дня"), (#"сегодня вечером"#, "вечер"), (#"к вечеру"#, "вечер"),
        (#"вечернему времени"#, "вечер"), (#"к утру"#, "утр"), (#"до конца месяца"#, "месяц"),
        (#"к следующей встрече"#, "следующей встрече"),
    ]

    // MARK: - Разбор

    public static func findings(recap: String, transcript: String) -> [Finding] {
        let body = withoutSystemBlocks(recap)
        var found: [Finding] = []

        let haystack = normalized(transcript)
        let hay = normalized(body)
        for deadline in deadlines {
            guard let quote = firstMatch(deadline.phrase, in: hay) else { continue }
            if !haystack.contains(deadline.stem) {
                found.append(Finding(kind: .unspokenDeadline, text: quote))
            }
        }

        for pattern in ghostOwner {
            for quote in matches(pattern, in: body, group: 1) {
                found.append(Finding(kind: .ghostOwner, text: quote))
            }
        }
        for quote in matches(inventedActor, in: body, group: 1) {
            found.append(Finding(kind: .inventedActor, text: quote))
        }
        found += matches(computedDeadline, in: body).map { Finding(kind: .computedDeadline, text: $0) }
        for quote in matches(imperative, in: body, group: 1) {
            found.append(Finding(kind: .imperative, text: quote))
        }
        for pattern in passive {
            found += matches(pattern, in: body).map { Finding(kind: .passive, text: $0) }
        }
        for pattern in clerical {
            found += matches(pattern, in: body).map { Finding(kind: .clerical, text: $0) }
        }
        for pattern in filler {
            found += matches(pattern, in: body).map { Finding(kind: .filler, text: $0) }
        }
        for sentence in sentences(of: body) {
            let words = sentence.split(whereSeparator: \.isWhitespace).count
            if words > maxSentenceWords {
                found.append(Finding(kind: .longSentence, text: "\(words) слов"))
            }
        }
        return found
    }

    /// Из чего состоит конспект: заголовки секций и число пунктов.
    ///
    /// Нужно, чтобы поймать редактуру, которая «улучшила» текст, выбросив кусок.
    /// Первая версия считала только пункты — и пропустила, как редактор целиком
    /// удалил «Ход обсуждения»: секция состоит из абзацев, счётчик пунктов её не
    /// видел. Проверять надо то, что можно потерять, а не то, что легче счесть.
    public struct Shape: Equatable {
        public let sections: [String]
        public let bullets: Int

        public init(sections: [String], bullets: Int) {
            self.sections = sections
            self.bullets = bullets
        }

        /// Потеряла ли правка содержание. Треть пунктов — порог замера: в
        /// лаборатории здоровая редактура ужимала список на 2–3 пункта из 17,
        /// а сорвавшаяся выбрасывала половину.
        public func lostContentComparedTo(_ before: Shape) -> String? {
            let missing = before.sections.filter { !sections.contains($0) }
            if !missing.isEmpty {
                return "пропала секция «\(missing.joined(separator: "», «"))»"
            }
            if before.bullets > 0, bullets * 3 < before.bullets * 2 {
                return "пунктов стало \(bullets) вместо \(before.bullets)"
            }
            return nil
        }
    }

    public static func shape(of recap: String) -> Shape {
        let body = withoutSystemBlocks(recap)
        let sections = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        let bullets = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .count
        return Shape(sections: sections, bullets: bullets)
    }

    /// Указания редактору: описывают результат, а не приказывают.
    ///
    /// Формулировка здесь не косметика. Первая версия говорила «убери»,
    /// «перепиши» — и модель перенесла этот тон в сам конспект: «Левон —
    /// проведите очистку», девять раз на восьми встречах. Отсюда `.imperative`
    /// в проверках и изъявительное наклонение в каждой строке ниже.
    public static func editorNotes(_ findings: [Finding], limit: Int = maxNotes) -> String {
        guard !findings.isEmpty else { return "" }

        // Порядок важен: список обрезается, и обрезаться должны длинные
        // предложения, а не выдуманный срок.
        var notes: [String] = []
        for kind in Kind.allCases {
            for finding in findings where finding.kind == kind {
                notes.append("- " + note(for: finding))
                if notes.count >= limit { break }
            }
            if notes.count >= limit { break }
        }
        return "\n\nНАЙДЕННЫЕ МЕСТА — проверено по транскрипту, каждое должно уйти:\n"
            + notes.joined(separator: "\n")
    }

    private static func note(for finding: Finding) -> String {
        switch finding.kind {
        case .unspokenDeadline:
            return "срок «\(finding.text)» на встрече не звучал — в исправленном тексте его нет, задача осталась"
        case .ghostOwner:
            return "«\(finding.text)» — не ответственный: в исправленном тексте пункт стоит без имени"
        case .inventedActor:
            return "«\(finding.text)» — такого участника на встрече не было: в исправленном тексте здесь «Договорились…» или имя, которое звучало"
        case .computedDeadline:
            return "срок «\(finding.text)» посчитан, а не назван: в исправленном тексте срока нет, задача осталась"
        case .imperative:
            return "«\(finding.text)» — приказ читателю: в исправленном тексте здесь рассказ о том, что было"
        case .passive:
            return "пассив «\(finding.text)» — в исправленном тексте здесь глагол с действующим лицом"
        case .clerical:
            return "канцелярит «\(finding.text)» — в исправленном тексте его нет"
        case .filler:
            return "общее слово «\(finding.text)» — в исправленном тексте его нет, если без него понятно"
        case .longSentence:
            return "предложение из \(finding.text) — в исправленном тексте на его месте два"
        }
    }

    // MARK: -

    /// Убрать то, что приписало приложение: заголовок документа и дословный
    /// блок заметок. Иначе редактор правил бы наш собственный текст и заметки
    /// пользователя, которые правке не подлежат.
    static func withoutSystemBlocks(_ recap: String) -> String {
        var body = recap
        if let heading = firstRange(#"(?m)\A#\s+.*\n"#, in: body) {
            body.removeSubrange(heading)
        }
        if let front = firstRange(#"(?s)\A---\n.*?\n---\n"#, in: body) {
            body.removeSubrange(front)
        }
        if let notes = firstRange(#"(?m)^##\s+Заметки\s*$"#, in: body) {
            body = String(body[body.startIndex..<notes.lowerBound])
        }
        return body
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func sentences(of body: String) -> [String] {
        body
            .replacingOccurrences(of: #"(?m)^[#\-*\s]+"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(whereSeparator: \.isWhitespace).count > 2 }
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let found = Range(match.range(at: group), in: text) else { return nil }
            return String(text[found])
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first
    }

    private static func firstRange(_ pattern: String, in text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: .regularExpression)
    }
}
