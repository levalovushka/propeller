import Foundation

/// # Одно написание имени в готовом конспекте
///
/// Журнал окна звонилки подписывает реплику так, как человек назвал себя в Zoom
/// («Arina Soldatenkova»), а конспект пишется по-русски — и модель половину
/// такого имени переводит. В живом конспекте 2026-08-20 стоит «Арина
/// Soldatenkova»: один человек в двух алфавитах внутри одного слова-и-фамилии.
///
/// Это не косметика. Исполнитель сверяется с составом по токенам
/// (`RecapLint.assigneesOutsideRoster`), и сверка ищет **хотя бы один**
/// совпавший токен: «Арина Soldatenkova» проходит её за счёт фамилии, а «Арина»
/// против ленточного «Arina Soldatenkova» не проходит вовсе — и **верное имя
/// становится находкой**, то есть единственная защита от выдуманного
/// ответственного тратится на правду. Проверено обоими случаями в
/// `PersonCanonTests`. Второй довод остаётся и там, где сверка не сломалась:
/// один человек в архиве не должен быть записан двумя способами.
///
/// Поэтому написание чинится кодом и **до** редактуры: всё, что можно снять без
/// модели, снимается без модели (то же правило, что у `RecapLint.grounded` и
/// `TermCanon`; редактор исполняет треть адресов, замер 2026-08-12).
///
/// **Канон — написание из состава**, то есть из подписей самой ленты: читатель
/// конспекта должен найти этого человека в расшифровке глазами. Правится только
/// конспект — лента остаётся как подписана (решение владельца 2026-08-20:
/// переименование в ленте — работа про механику имён, а не про саммари).
///
/// **Чего эта замена не делает, сознательно:**
///
/// - **не трогает косвенные падежи.** Меняется только точное совпадение
///   свёртки: «Арине» → «Arina» сломало бы фразу. Косые формы остаются
///   находкой редактору — он их и переписывает;
/// - **не трогает регистр.** «Костя» против ленточного «костя» — разница в
///   заглавной букве, и опустить её посреди предложения значило бы починить
///   сверку ценой опечатки в тексте;
/// - **не сшивает разные имена одного человека.** Транслитерация одна и грубая:
///   «Александр» и «Alexander» она не соединит, потому что это перевод имени, а
///   не его написание. Такое остаётся редактору.
public enum PersonCanon {

    /// Кириллица в латиницу, одна грубая схема. Не транслитерация для человека,
    /// а ключ сравнения: важно только, чтобы «Арина» и «Arina» дали одну
    /// строку, и чтобы два разных человека её не поделили.
    private static let translit: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"
    ]

    /// Ключ сравнения: нижний регистр, кириллица переведена, всё, что не буква,
    /// выброшено.
    static func fold(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if let mapped = translit[character] {
                out += mapped
            } else if character.isLetter {
                out.append(character)
            }
        }
        return out
    }

    /// Свёртка → написание из состава. Коллизия двух разных участников убивает
    /// ключ: угадать, кто из них имелся в виду, нечем, а угаданное имя хуже
    /// разнописания.
    static func table(roster: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var banned: Set<String> = []

        func offer(_ key: String, _ literal: String) {
            guard key.count >= 3, !banned.contains(key) else { return }
            if let existing = out[key], fold(existing) == key, existing != literal {
                // Одна свёртка на двух написаниях состава: сам состав уже
                // разнописан — не наш случай, и выбирать за человека нечего.
                out[key] = nil
                banned.insert(key)
                return
            }
            if out[key] == nil { out[key] = literal }
        }

        for name in roster {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            offer(fold(trimmed), trimmed)
        }
        // Отдельные слова — «Арина» в тексте против «Arina Soldatenkova» в
        // составе. Только если слово принадлежит ровно одному участнику.
        var owners: [String: Set<String>] = [:]
        for name in roster {
            for word in name.components(separatedBy: CharacterSet.letters.inverted) where word.count >= 3 {
                owners[fold(word), default: []].insert(name)
            }
        }
        for name in roster {
            for word in name.components(separatedBy: CharacterSet.letters.inverted) where word.count >= 3 {
                let key = fold(word)
                guard owners[key]?.count == 1 else { continue }
                offer(key, word)
            }
        }
        return out
    }

    /// Слово с заглавной, до трёх слов подряд — кандидат на имя.
    private static let candidates = try! NSRegularExpression(
        pattern: #"\p{Lu}\p{L}+(?:[  ]\p{Lu}\p{L}+){0,2}"#
    )

    /// Привести имена в конспекте к написанию из состава.
    ///
    /// `roster` — подписи ленты (`RecapDocument.participants`); пустой состав
    /// значит «журнал молчал», и тогда текст не трогается вовсе.
    public static func normalize(_ recap: String, roster: [String]) -> String {
        let table = table(roster: roster)
        guard !table.isEmpty, !recap.isEmpty else { return recap }

        var edits: [(range: Range<String.Index>, replacement: String)] = []

        func planned(_ span: Substring) -> String? {
            guard let canon = table[fold(String(span))] else { return nil }
            guard canon != span else { return nil }
            // Разница только в регистре — не наше дело (см. док к типу).
            guard canon.lowercased() != span.lowercased() else { return nil }
            return canon
        }

        let whole = NSRange(recap.startIndex..., in: recap)
        candidates.enumerateMatches(in: recap, range: whole) { match, _, _ in
            guard let match, let range = Range(match.range, in: recap) else { return }
            let span = recap[range]
            if let canon = planned(span) {
                edits.append((range, canon))
                return
            }
            // Целиком не совпало — пробуем слова внутри: «Арина Soldatenkova»
            // против состава «Arina Soldatenkova» лечится по слову.
            var index = range.lowerBound
            while index < range.upperBound {
                guard recap[index].isLetter else {
                    index = recap.index(after: index)
                    continue
                }
                var end = index
                while end < range.upperBound, recap[end].isLetter {
                    end = recap.index(after: end)
                }
                let word = recap[index..<end]
                if let canon = planned(word) {
                    edits.append((index..<end, canon))
                }
                index = end
            }
        }

        guard !edits.isEmpty else { return recap }
        var out = recap
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: edit.replacement)
        }
        return out
    }
}
