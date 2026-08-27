import Foundation

/// # Разметка задачи приводится к канону кодом, а не просьбой к модели
///
/// Канон — `plan-projects.md` §4.1, решение владельца 2026-08-27:
///
/// ```
/// - [ ] **Левон** — написать Дену; до 19:00 завтра
/// - [x] **Ilyas Aitkulov** — обновить макеты
/// - [ ] обсудить flow демоскирования
/// ```
///
/// Промпт просит именно это, и модель слушается непоследовательно. Замер по
/// живому архиву (73 конспекта, 186 задач, 2026-08-27):
///
/// | что стоит в файле | сколько |
/// |---|---|
/// | `**Имя** — …` — разбирается | 120 |
/// | имени нет вовсе | 38 |
/// | `Имя — …` без жирного | 14 |
/// | `**Имя**: …` двоеточие вместо тире | 9 |
/// | `**Имя** глагол …` без тире | 4 |
///
/// **23 задачи из 186 теряют человека на разборе, хотя имя в строке стоит** — не
/// хватает только звёздочек и длинного тире (четвёртый вид, `**Имя** глагол`,
/// сознательно оставлен модели — см. `ownerHead`). Это чинится без модели, значит
/// чинится без модели: то же правило, по которому живут `RecapLint.grounded`,
/// `PersonCanon` и `TermCanon` — редактор исполняет треть отданных ему адресов
/// (замер 2026-08-12).
///
/// # Ростер — не украшение, а вся защита
///
/// Каждое правило ниже срабатывает **только если имя свёрнуто совпало с
/// составом встречи** (`PersonCanon.table`, тот же ключ сравнения, что у
/// канонизации написаний). Без этой заслонки первое же правило сделает
/// ответственным слово «Команда» или «Обед», а назначить работу тому, кто её не
/// брал, хуже, чем оставить задачу без имени (`plan-projects.md` §4.3, и тот же
/// урок в `RecapLint.ghostOwnerHead`). Состав пуст — модуль не трогает имена
/// вовсе, только ставит чекбоксы.
///
/// # Чего он не делает
///
/// **Не переносит пункты между секциями.** Решение, написанное в форме
/// поручения, — ошибка не разметки, а формулировки: переписать его может только
/// модель, и она получает адрес находкой `RecapLint.Kind.decisionAsTask`.
///
/// **Не ставит чекбоксов.** Промпт их просит (§4.1), и это решение владельца;
/// дописывать их здесь каждой задаче — другое дело, и оно упирается в открытый
/// вопрос `plan-projects.md` §4.5: у `SummaryDocument` нет вида «задача», и
/// панель саммари рисует `- [ ] дело` как «• [ ] дело», буквальными скобками.
/// Сейчас чекбокс стоит в 1 задаче архива из 186 — то есть цена этого вопроса
/// ещё не заплачена, и оплачивать её молча, из модуля про разметку, нельзя.
/// Вкладке «Задачи» чекбокс в файле и не нужен: пункт без скобок — не сделан,
/// и галочку по клику ставит `RecapAtom.toggled()`.
///
/// **Не додумывает состояние.** Задача в прошедшем времени («**Левон** —
/// пересобрал Гант», 12 пунктов архива) — дефект формулировки, а не галочка;
/// это адрес редактору, а не правка здесь.
///
/// **Не трогает секцию «Решения».** У решения нет ни ответственного, ни
/// чекбокса — их там не появляется (`ProjectTab.itemsAreCheckable`).
public enum RecapAtomCanon {

    public struct Result: Equatable {
        public let recap: String
        /// Что привели к канону, цитатами. Пусто — конспект и так был по канону.
        /// Возвращается по той же причине, что у `RecapLint.Grounding.removed`:
        /// правка, молча переписывающая чужой текст, должна уметь сказать, что
        /// именно она переписала.
        public let fixed: [String]

        public init(recap: String, fixed: [String]) {
            self.recap = recap
            self.fixed = fixed
        }
    }

    /// Привести ответственного в секции «Задачи» к канону разметки.
    ///
    /// `roster` — подписи ленты (`RecapDocument.participants`), те же, что
    /// уходят в промпт и в `PersonCanon`.
    public static func canonical(_ recap: String, roster: [String]) -> Result {
        guard !recap.isEmpty else { return Result(recap: recap, fixed: []) }

        let names = PersonCanon.table(roster: roster)
        var fixed: [String] = []
        var lines = recap.components(separatedBy: "\n")
        var inTasks = false

        for index in lines.indices {
            // Возврат каретки снимается и возвращается на место: файл с
            // виндовыми окончаниями строк уже однажды порвали правкой, которая
            // о них не знала.
            let carriage = lines[index].hasSuffix("\r")
            let line = carriage ? String(lines[index].dropLast()) : lines[index]

            if let heading = RecapDigest.headingTitle(
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            ) {
                inTasks = RecapDigest.foldTitle(heading)
                    == RecapDigest.foldTitle(RecapDigest.tasksTitle)
                continue
            }
            guard inTasks, let split = bullet(line) else { continue }

            guard let owner = canonicalOwner(split.body, names: names) else { continue }
            fixed.append(owner.quote)
            lines[index] = split.prefix + owner.body + (carriage ? "\r" : "")
        }
        return Result(recap: lines.joined(separator: "\n"), fixed: fixed)
    }

    // MARK: - Ответственный

    /// Пункт с ответственным в канонической разметке — или `nil`, если чинить
    /// нечего и если чинить нечем.
    private static func canonicalOwner(
        _ item: String, names: [String: String]
    ) -> (body: String, quote: String)? {
        guard !names.isEmpty else { return nil }

        let boxEnd = leadingCheckboxEnd(item)
        let box = boxEnd.map { String(item[item.startIndex..<$0]) } ?? ""
        var rest = boxEnd.map { String(item[$0...]) } ?? item
        let leading = rest.prefix(while: { $0 == " " })
        rest = String(rest.dropFirst(leading.count))

        guard let owner = ownerHead(rest, names: names) else { return nil }
        let tail = String(rest[owner.end...]).trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }
        let canon = "**\(owner.name)** — " + tail
        guard canon != rest else { return nil }
        return (box + leading + canon, String(rest.prefix(owner.quoteLength)))
    }

    /// Два вида, которыми модель пишет ответственного мимо канона. Оба — строки
    /// живого архива; порядок проверок от самого частого к самому редкому.
    ///
    /// Третьего вида — `**Имя** глагол …` совсем без разделителя — здесь нет
    /// сознательно. В архиве таких четыре из 186, а отличить исполнителя от
    /// жирного начала фразы можно только по следующему слову: «**Левон** и Саша
    /// соберут» превратилось бы в «**Левон** — и Саша соберут». Правило, которое
    /// держится на списке союзов, портит текст ради двух процентов пунктов.
    private static func ownerHead(
        _ text: String, names: [String: String]
    ) -> (name: String, end: String.Index, quoteLength: Int)? {
        // 1. `**Имя**:` или `**Имя** -`. Длинное и среднее тире уже канон, их
        //    `RecapAtom` разбирает сам.
        if text.hasPrefix("**"),
           let closing = text.range(
               of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex
           ) {
            let name = String(text[text.index(text.startIndex, offsetBy: 2)..<closing.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard let canon = names[PersonCanon.fold(name)] else { return nil }
            var after = closing.upperBound
            while after < text.endIndex, text[after] == " " { after = text.index(after: after) }
            guard after < text.endIndex, ":-".contains(text[after]) else { return nil }
            after = text.index(after: after)
            while after < text.endIndex, text[after] == " " { after = text.index(after: after) }
            return (canon, after, text.distance(from: text.startIndex, to: after))
        }

        // 2. `Имя — …` и `Имя: …` без жирного. Тире именно длинное или среднее:
        //    по дефису рвались бы «Иванов-Петров» и «веб-стор». Разделитель
        //    берётся самый левый — иначе двоеточие из середины фразы утащило бы
        //    в имя половину пункта.
        let separators = [" — ", " – ", ": "]
        guard let range = separators
            .compactMap({ text.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let head = String(text[text.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !head.contains("*"), head.count <= 60,
              let first = head.first, first.isUppercase,
              let canon = names[PersonCanon.fold(head)]
        else { return nil }
        let end = range.upperBound
        return (canon, end, text.distance(from: text.startIndex, to: end))
    }

    // MARK: -

    /// Отступ с маркером списка и то, что стоит после них.
    private static func bullet(_ line: String) -> (prefix: String, body: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        for marker in ["- ", "* ", "• "] where rest.hasPrefix(marker) {
            let body = String(rest.dropFirst(marker.count))
            guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (String(indent) + marker, body)
        }
        return nil
    }

    /// Конец `[ ]` / `[x]` в начале пункта, вместе со следующими за ним
    /// пробелами — или `nil`, если чекбокса нет.
    private static func leadingCheckboxEnd(_ text: String) -> String.Index? {
        guard text.hasPrefix("[") else { return nil }
        let mark = text.index(after: text.startIndex)
        guard mark < text.endIndex, " xX✓".contains(text[mark]) else { return nil }
        let close = text.index(after: mark)
        guard close < text.endIndex, text[close] == "]" else { return nil }
        var end = text.index(after: close)
        while end < text.endIndex, text[end] == " " { end = text.index(after: end) }
        return end
    }
}
