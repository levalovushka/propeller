import Foundation

/// # Где в конспекте стоят твои заметки
///
/// Сразу под «Итогом» и перед первым разделом, который написала модель. Это не
/// вкусовое место: «Итог» — ответ машины на вопрос «о чём была встреча», а
/// заметки — то, что важным счёл ты, и читаются они раньше её разбора. Внизу
/// файла, где они лежали, их находил только тот, кто дочитал.
///
/// Раздел принадлежит человеку целиком. Модель просят вплетать заметки по
/// смыслу, а не выносить списком, поэтому свой «Заметки» она выдавать не должна;
/// если всё же выдала — он выбрасывается, а не соседствует со вторым таким же.
/// Спорить с моделью о том, чей это раздел, дешевле один раз здесь, чем каждый
/// раз глазами.
public enum RecapNotes {

    public static let heading = "## Заметки"

    /// Вставить блок заметок в тело конспекта.
    ///
    /// Пустые заметки — не блок: пустой раздел в файле ничем не отличается от
    /// раздела, который забыли заполнить.
    public static func placed(_ notes: String?, into body: String) -> String {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return stripped(body) }

        var lines = stripped(body).components(separatedBy: "\n")
        let block = ["", heading, "", trimmed]

        // Перед вторым заголовком: первый — «Итог», и заметки идут после него.
        // Заголовка второго нет (конспект в один раздел или вовсе без них) —
        // значит после всего, потому что вставлять их некуда, а терять нельзя.
        if let insertion = headingIndices(in: lines).dropFirst().first {
            lines.insert(contentsOf: block, at: insertion)
            // Пустая строка перед следующим заголовком — иначе разбор склеит
            // последнюю строку заметки с ним.
            lines.insert("", at: insertion + block.count)
        } else {
            lines.append(contentsOf: block)
        }
        return lines.joined(separator: "\n")
    }

    /// Тот же конспект без раздела заметок — что бы в нём ни лежало.
    ///
    /// Нужен и на входе (убрать раздел, выданный моделью), и сам по себе: файл,
    /// собранный прошлой сборкой, несёт этот раздел в конце, и второй раз
    /// дописывать его нельзя.
    public static func stripped(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { isNotesHeading($0) }) else { return body }
        let rest = lines[(heading + 1)...]
        let end = rest.firstIndex(where: { isHeading($0) }) ?? lines.endIndex
        // Пустые строки перед заголовком принадлежат ему: они отделяли его от
        // предыдущего раздела, и без него отделять нечего. Оставленные, они
        // копятся — конспект, прошедший сборку дважды, расходится на пустой
        // строке каждый раз.
        var start = heading
        while start > 0, isBlank(lines[start - 1]) { start -= 1 }
        lines.removeSubrange(start..<end)
        // Один пустой шов между соседями, которые оказались рядом.
        if start > 0, start < lines.count { lines.insert("", at: start) }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Строки-заголовки. Только настоящие `##`: голая строка перед списком —
    /// это догадка разбора для съехавшего markdown, и место в файле на догадке
    /// строить нельзя.
    private static func headingIndices(in lines: [String]) -> [Int] {
        lines.indices.filter { isHeading(lines[$0]) }
    }

    private static func isHeading(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("##")
    }

    private static func isNotesHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("##") else { return false }
        let title = trimmed.drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return title == "заметки"
    }
}
