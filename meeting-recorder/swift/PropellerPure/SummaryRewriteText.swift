import Foundation

/// Ответ модели перед подстановкой в выделение.
///
/// Выделение жило внутри одного блока. Модель на «Подробнее» часто возвращает
/// несколько абзацев, `-` списки и `**жирное**`. Вставка как есть режет блок
/// переводами строк: новые абзацы наследуют `bullet`, но без маркера `•\t` —
/// вёрстка едет, а каретка при каждом щелчке прыгает на два символа вперёд
/// (`keepCaretOutOfBulletMarker` думает, что там диск).
///
/// Поэтому ответ сплющивается в одну строку, структурная разметка снимается,
/// а inline `**` / `*` превращается в те же spans, которыми саммари и живёт.
public enum SummaryRewriteText {

    /// Готовый к вставке текст: spans с выделением, без переносов и списков.
    public static func prepare(_ raw: String) -> [SummaryDocument.Span] {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // Маркеры списка на каждой строке — до сплющивания, иначе `-` останется
        // посреди предложения.
        text = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripLeadingStructure(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        text = collapseSpaces(text)
        guard !text.isEmpty else { return [] }
        return SummaryDocument.spans(inline: text)
    }

    /// Плоская строка — то, что увидит человек, без markdown-маркеров.
    public static func plain(_ raw: String) -> String {
        prepare(raw).map(\.text).joined()
    }

    // MARK: -

    private static func stripLeadingStructure(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text = String(text.drop(while: { $0 == "#" }))
                .trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["- ", "* ", "•\t", "• "] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
        }
        // После trim у `- ` остаётся голый `-` — это не текст фрагмента.
        if text == "-" || text == "*" || text == "•" { return "" }
        return text
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
