import Foundation

/// Решение или задача, разобранные из строки конспекта.
///
/// Разметка согласована владельцем 2026-08-27 (`plan-projects.md` §4.1):
///
/// ```
/// - [ ] **Левон** — написать Дену; до 19:00 завтра
/// - [x] **Ilyas Aitkulov** — обновить макеты
/// - [ ] обсудить flow демоскирования
/// ```
///
/// Разбирается то, что стоит **после** маркера списка: `RecapDigest` его уже
/// снял. Дальше по порядку — `[ ]` или `[x]`, затем `**Имя**` перед ` — `.
///
/// # Чего разбор не делает
///
/// **Не додумывает.** Нет квадратных скобок — задача не сделана и галочки в
/// файле нет; нет жирного — ответственного нет, даже если имя стоит прозой
/// (`plan-projects.md` §4.3). Угадывание по началу строки однажды сделает
/// ответственным слово «Команда»: на 211 задачах архива жирный ответственный
/// стоит в 136 строках, тире без жирного ещё в ~20, а в 55 нет ни того ни
/// другого.
///
/// **Не приводит к канону.** Строка возвращается в файл ровно из тех частей, на
/// которые была разобрана; всё, чего разбор не понял, лежит в `body` как есть.
public struct RecapAtom: Equatable, Sendable {

    /// Что стоит в квадратных скобках — и стоит ли вообще.
    public enum Checkbox: Equatable, Sendable {
        case todo
        case done
    }

    /// `nil` — скобок в строке нет. Это не то же самое, что `.todo`: у пункта
    /// без скобок галочки в файле нет, и поставить её — правка файла, а не
    /// смена вида.
    public let checkbox: Checkbox?
    /// Кто отвечает — только если имя стояло жирным перед тире.
    public let assignee: String?
    /// Всё остальное, дословно.
    public let body: String

    public init(checkbox: Checkbox? = nil, assignee: String? = nil, body: String) {
        self.checkbox = checkbox
        self.assignee = assignee
        self.body = body
    }

    public var isDone: Bool { checkbox == .done }

    // MARK: - Разбор

    public static func parse(_ item: String) -> RecapAtom {
        var rest = Substring(item)
        var checkbox: Checkbox?

        if let box = leadingCheckbox(rest) {
            checkbox = box.state
            rest = rest[box.end...].drop(while: { $0 == " " })
        }

        if let owner = leadingAssignee(rest) {
            return RecapAtom(
                checkbox: checkbox,
                assignee: owner.name,
                body: String(rest[owner.end...]).trimmingCharacters(in: .whitespaces)
            )
        }
        return RecapAtom(checkbox: checkbox, assignee: nil, body: String(rest))
    }

    /// `[ ]`, `[x]`, `[X]` в начале строки.
    private static func leadingCheckbox(
        _ text: Substring
    ) -> (state: Checkbox, end: Substring.Index)? {
        guard text.first == "[" else { return nil }
        let after = text.index(after: text.startIndex)
        guard after < text.endIndex else { return nil }
        let mark = text[after]
        let close = text.index(after: after)
        guard close < text.endIndex, text[close] == "]" else { return nil }
        switch mark {
        case " ": return (.todo, text.index(after: close))
        case "x", "X", "✓": return (.done, text.index(after: close))
        default: return nil
        }
    }

    /// `**Имя** — ` в начале строки. Тире именно длинное: короткий дефис живёт
    /// внутри имён и дат, и разбирать по нему значило бы рвать «Иванов-Петров».
    private static func leadingAssignee(
        _ text: Substring
    ) -> (name: String, end: Substring.Index)? {
        guard text.hasPrefix("**"), let closing = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex)
        else { return nil }
        let name = text[text.index(text.startIndex, offsetBy: 2)..<closing.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let tail = text[closing.upperBound...]
        for dash in dashes where tail.hasPrefix(" \(dash) ") {
            return (name, tail.index(tail.startIndex, offsetBy: dash.count + 2))
        }
        return nil
    }

    /// Тире, которыми модель отделяет ответственного. Длинное и среднее — оба
    /// встречаются в архиве; дефиса здесь нет намеренно.
    private static let dashes: [String] = ["—", "–"]

    // MARK: - Сборка обратно

    /// Строка для файла — без маркера списка: его ставит `RecapItemEdit`.
    ///
    /// Скобок здесь нет, хотя разбор их читает, и это не забывчивость. Галочка
    /// в конспекте была нашим таск-трекером (`ProjectTab`), которым мы не
    /// работаем: единственное, что её ставило, — квадрат на вкладке «Задачи»,
    /// и он же дописывал `[x]` в файл встречи. Квадрата больше нет, писать
    /// скобки стало нечему — а раз так, то и обратно в файл они не уезжают.
    /// Читать старый файл со скобками это не мешает: `parse` их понимает,
    /// `isDone` отвечает; правка строки просто возвращает её без них.
    public var item: String {
        var out = ""
        if let assignee, !assignee.isEmpty { out += "**\(assignee)** — " }
        return out + body
    }

    /// Тот же пункт без ответственного.
    public func withoutAssignee() -> RecapAtom {
        RecapAtom(checkbox: checkbox, assignee: nil, body: body)
    }

    /// Тот же пункт с назначенным ответственным. Имя уходит в файл жирным, и
    /// разбор его оттуда потом узнает — правило «нет жирного, нет и
    /// ответственного» работает в обе стороны.
    public func with(assignee: String) -> RecapAtom {
        let name = assignee.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? withoutAssignee()
                            : RecapAtom(checkbox: checkbox, assignee: name, body: body)
    }

    /// Тот же пункт с другой формулировкой. Галочка и ответственный остаются:
    /// карандаш правит текст, а не то, кто отвечает и сделано ли.
    public func with(body: String) -> RecapAtom {
        RecapAtom(checkbox: checkbox, assignee: assignee,
                  body: body.trimmingCharacters(in: .whitespaces))
    }
}
