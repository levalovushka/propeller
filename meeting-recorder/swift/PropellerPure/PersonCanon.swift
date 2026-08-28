import Foundation

/// # Одно написание имени в готовом конспекте
///
/// Журнал окна звонилки подписывает реплику так, как человек назвал себя в Zoom
/// («Marina Primer»), а конспект пишется по-русски — и модель половину
/// такого имени переводит. В живом конспекте 2026-08-20 стоит «Марина
/// Primer»: один человек в двух алфавитах внутри одного слова-и-фамилии.
///
/// Довод один и он простой: **один человек не должен быть записан в архиве
/// двумя способами** — ни в конспекте, ни между конспектом и лентой.
///
/// Довод был другой, и он оказался ложным. Написание чинилось затем, что сверка
/// исполнителя с составом (`RecapLint.assigneesOutsideRoster`) сравнивала сырые
/// строки и «Марина» против ленточного «Marina Primer» не проходила вовсе —
/// верное имя становилось находкой. Из этой одной строки выросла круговая
/// правка в проде: здесь имя гнали в латиницу до редактуры, а `RecapFormCanon`
/// возвращал его в кириллицу после. Матчер линтера с 2026-08-28 зовёт `fold`,
/// алфавит в сверке не считается, и круг разомкнут.
///
/// Написание всё равно чинится кодом и **до** редактуры: всё, что можно снять
/// без модели, снимается без модели (то же правило, что у `RecapLint.grounded` и
/// `TermCanon`; редактор исполняет треть адресов, замер 2026-08-12), а редактор
/// не тратит находку на разнописание.
///
/// **Канон — кириллическое личное имя, подтверждённое транскриптом**, а когда
/// подтвердить нечем — написание из состава, то есть из подписей самой ленты.
///
/// Так не было. Канон был «написание из состава» и только: читатель конспекта
/// должен найти человека в расшифровке глазами. Цена этого правила видна на
/// живом конспекте 2026-08-28: состав пришёл из Zoom латиницей, и **мы**
/// переписывали русское «Полина уточняет вопрос» в «Polina» — то есть тянули
/// русский документ в латиницу. Владелец: «а я хочу на кириллице». Оба довода
/// сходятся на транскрипте: имя, которым человека зовут вслух на встрече, и
/// найдётся в расшифровке глазами, и стоит в конспекте по-русски (`written`).
///
/// Правится только конспект — лента остаётся как подписана (решение владельца
/// 2026-08-20: переименование в ленте — работа про механику имён, а не про
/// саммари).
///
/// **Чего эта замена не делает, сознательно:**
///
/// - **не трогает косвенные падежи.** Меняется только точное совпадение
///   свёртки: «Марине» → «Marina» сломало бы фразу. Косые формы остаются
///   находкой редактору — он их и переписывает;
/// - **не трогает регистр.** «Боря» против ленточного «боря» — разница в
///   заглавной букве, и опустить её посреди предложения значило бы починить
///   сверку ценой опечатки в тексте;
/// - **не сшивает разные имена одного человека.** Транслитерация одна и грубая:
///   «Александр» и «Alexander» она не соединит, потому что это перевод имени, а
///   не его написание. Такое остаётся редактору.
///
/// Исключение из первого пункта одно, и оно про фамилию, а не про падеж:
/// «Полина Кременец» при ленточном «Polina Kremenets» — тот же человек,
/// названный своим написанием, и он становится «Полиной»
/// (`spelledItsOwnWay`). Фамилия при этом уходит: подтвердить её написание
/// нечем — в транскрипте её нет ни в одном виде.
///
/// **А там, где имя — не проза, а поле, канон выполняется буквально.** В слоте
/// ответственного задачи стоит одно написание на человека, по любому его слову:
/// «Vlad» → «Влад». Это `RecapFormCanon.assigneeName`, и там же разобрано,
/// почему подстановка, недопустимая в прозе, обязательна в поле.
public enum PersonCanon {

    /// Кириллица в латиницу, одна грубая схема. Не транслитерация для человека,
    /// а ключ сравнения: важно только, чтобы «Марина» и «Marina» дали одну
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
        // Отдельные слова — «Марина» в тексте против «Marina Primer» в
        // составе. Только если слово принадлежит ровно одному участнику.
        let owners = soleOwners(roster: roster)
        for name in roster {
            for word in words(of: name) where owners[fold(word)] != nil {
                offer(fold(word), word)
            }
        }
        return out
    }

    /// Слова имени, годные в ключ. Короче трёх букв не считается: «Ян» как
    /// отдельное слово встречается в тексте по другим поводам — та же граница,
    /// что у `PersonName.minStandaloneForm`.
    static func words(of name: String) -> [String] {
        name.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
    }

    /// Свёртка слова → участник состава, которому это слово принадлежит, —
    /// только там, где владелец **один**.
    ///
    /// Вынесено из `table`, потому что у правила два читателя: канон имён в
    /// конспекте и сборка рядов встречи (`MeetingRoster`), где «Полина» из ленты
    /// должна сойтись с «Polina Kremenets» из плитки. Два выражения одного
    /// правила в этом коде уже стоили инертного ростера в промпте (2026-08-20),
    /// и второй раз их разводить не за чем.
    ///
    /// Спорное слово выпадает целиком: у «Александра Яшина» и «Александра
    /// Образцова» общее первое слово, и голое «Александр» не значит ни того, ни
    /// другого. Промолчать здесь дешевле, чем угадать.
    static func soleOwners(roster: [String]) -> [String: String] {
        var owners: [String: Set<String>] = [:]
        for name in roster {
            for word in words(of: name) { owners[fold(word), default: []].insert(name) }
        }
        return owners.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// Латиница обратно в кириллицу — **точная инверсия** `translit`.
    ///
    /// Нужна затем, что состав это то, что человек набрал в Zoom («Vlad
    /// Aldokhin»), а конспект пишется по-русски. Инверсия именно точная: свёртка
    /// полученного слова обязана совпасть со свёрткой исходного, иначе имя
    /// станет «исполнителем вне состава» для `RecapLint`, то есть починка формы
    /// сломала бы сверку людей.
    ///
    /// **И этого мало.** Инверсия round-trip'ится и на неверном написании:
    /// «Mikhail» → «Микхаил» свернётся в `mikhail` и проверку пройдёт, а имени
    /// такого нет. Поэтому одна эта функция ничего не решает — тот, кто её
    /// зовёт, обязан подтвердить результат текстом встречи
    /// (`RecapFormCanon.assigneeName`). Транслитерация предлагает, транскрипт
    /// подтверждает.
    ///
    /// `nil` — в слове есть буква, которой в схеме нет (`j`, `q`, `w`, `x`):
    /// гадать про неё не за что.
    static func cyrillic(_ latin: String) -> String? {
        // Длинные сочетания первыми, иначе «sch» разберётся как «s» + «ch».
        let pairs: [(String, String)] = [
            ("sch", "щ"), ("zh", "ж"), ("ch", "ч"), ("sh", "ш"), ("yu", "ю"), ("ya", "я"),
            ("a", "а"), ("b", "б"), ("v", "в"), ("g", "г"), ("d", "д"), ("e", "е"),
            ("z", "з"), ("i", "и"), ("k", "к"), ("l", "л"), ("m", "м"), ("n", "н"),
            ("o", "о"), ("p", "п"), ("r", "р"), ("s", "с"), ("t", "т"), ("u", "у"),
            ("f", "ф"), ("h", "х"), ("c", "ц"), ("y", "ы"),
        ]
        var rest = Substring(latin.lowercased())
        var out = ""
        outer: while !rest.isEmpty {
            for (from, to) in pairs where rest.hasPrefix(from) {
                out += to
                rest = rest.dropFirst(from.count)
                continue outer
            }
            return nil
        }
        guard !out.isEmpty, fold(out) == fold(latin) else { return nil }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// Есть ли в строке латинская буква. Ею отличается «уже по канону» от «надо
    /// переписать»: канон — кириллица, и кириллицу мы кириллицей не переписываем.
    private static func hasLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 128 && CharacterSet.letters.contains($0) }
    }

    /// Кириллическое личное имя участника — или `nil`, и тогда его зовут
    /// написанием из состава.
    ///
    /// # Три условия, и каждое снимает свой способ соврать
    ///
    /// 1. **Личное имя принадлежит одному участнику.** Двое Александров — и
    ///    «Александр» не значит ни одного из них (`soleOwners`).
    /// 2. **Транслитерация точная.** Обратная схема — инверсия `translit`
    ///    (`cyrillic`), и её результат обязан свернуться в то же, что исходник,
    ///    иначе имя станет «исполнителем вне состава» для линтера.
    /// 3. **Написание подтверждено транскриптом.** Это главное условие, потому
    ///    что второе проходит и неверное написание: «Mikhail» → «Микхаил»
    ///    сворачивается в `mikhail` и проверку сворачивания проходит. Поэтому
    ///    имя ищется в тексте самой встречи — там люди зовут друг друга по
    ///    имени, и «Влад», «Полина», «Анастасия» стоят по-русски. Не нашлось —
    ///    не подставляем: **транслитерация предлагает, транскрипт подтверждает.**
    ///
    /// Фамилию не транслитерируем никогда. «Aldokhin» — это «Алдохин» или
    /// «Алдёхин»? В транскрипте её нет ни в одном написании (замер по живой
    /// встрече: «Кременец» и «Алдохин» — ноль вхождений), то есть подтвердить
    /// нечем, а угадать чужую фамилию дороже, чем звать человека личным именем.
    ///
    /// Живёт здесь, а не в `RecapFormCanon`, где было написано: правило про
    /// **написание имени**, а не про форму конспекта, и читателей у него два —
    /// слот ответственного и проза (`normalize`).
    static func personal(of entry: String, roster: [String], transcript: String) -> String? {
        guard let first = words(of: entry).first else { return nil }
        // Личное имя должно принадлежать этому участнику одному.
        guard soleOwners(roster: roster)[fold(first)] == entry else { return nil }
        guard hasLatin(first) else { return first }   // состав и так по-русски
        guard let cyrillic = cyrillic(first), attested(cyrillic, in: transcript) else { return nil }
        return cyrillic
    }

    /// Стоит ли это написание в тексте встречи. Сравнение по началу слова:
    /// «Полина» в транскрипте живёт и как «Полины», и как «Полине».
    private static func attested(_ name: String, in transcript: String) -> Bool {
        let hay = transcript.lowercased().replacingOccurrences(of: "ё", with: "е")
        let word = name.lowercased().replacingOccurrences(of: "ё", with: "е")
        let stem = String(word.prefix(max(4, word.count - 2)))
        guard stem.count >= 4 else { return false }
        return hay.contains(stem)
    }

    /// Свёртка → **кириллическое личное имя**, подтверждённое транскриптом.
    ///
    /// Кладётся поверх `table` и ровно затем, что `table` тянет документ в
    /// латиницу: канон там — подпись из ленты, то есть то, что человек набрал в
    /// Zoom («Polina Kremenets»), — и в живом конспекте 2026-08-28 модель
    /// написала «Полина уточняет вопрос», а **мы** переписали это в «Polina».
    /// Канон — кириллица (решение владельца 2026-08-28): конспект русский, и
    /// человека в нём зовут так, как его зовут вслух на встрече.
    ///
    /// Ключей два на человека — полное имя и личное. Фамилия отдельным словом
    /// ключом не становится: «Kremenets» → «Полина» подменило бы фамилию именем.
    static func written(roster: [String], transcript: String) -> [String: String] {
        var out: [String: String] = [:]
        for name in roster {
            guard let personal = personal(of: name, roster: roster, transcript: transcript),
                  let first = words(of: name).first
            else { continue }
            out[fold(name)] = personal
            out[fold(first)] = personal
        }
        return out
    }

    /// Имя одного участника, части которого модель написала своим написанием:
    /// «Полина Кременец» против ленточного «Polina Kremenets», «Влад Альдохин»
    /// против «Vlad Aldokhin». Ни одной такой фамилии в транскрипте не звучит,
    /// подтвердить её написание нечем — и человек зовётся личным именем целиком.
    ///
    /// Здесь **уходит слово**, единственное место в этом типе, поэтому заслонок
    /// четыре: имя должно указывать ровно на одного участника состава, у него
    /// должно быть подтверждённое личное имя, **незнакомое слово обязано
    /// начинаться так же, как слово состава** — «kremenec» против «kremenets»
    /// это семь общих букв свёртки, «aldohin» против «aldokhin» — четыре, — и
    /// оно обязано этому слову **не совпадать**.
    ///
    /// Ниже четырёх правило молчит: поэтому «Влад Алодхин» (ASR услышал фамилию
    /// неверно) остаётся как написан, а «Левон Гант» не теряет «Гант» — у
    /// однословного участника состава сравнивать не с чем. А на совпадении
    /// молчит потому, что чинить нечего: «Борис Пример» написан верно, и то, что
    /// «Пример» выпал из `table`, значит лишь, что фамилию делят двое.
    private static func spelledItsOwnWay(
        _ span: Substring, roster: [String], written: [String: String]
    ) -> String? {
        let owners = soleOwners(roster: roster)
        var entry: String?
        var name: String?
        var unknown: [String] = []
        for word in words(of: String(span)) {
            guard let owner = owners[fold(word)] else { unknown.append(word); continue }
            if let entry, entry != owner { return nil }   // двое в одном имени
            entry = owner
            name = name ?? written[fold(word)]
        }
        guard let entry, let name, !unknown.isEmpty else { return nil }
        let parts = words(of: entry).map(fold)
        for word in unknown {
            let key = fold(word)
            // Совпавшее слово не считается **своим** написанием: «Пример» при
            // составе «Борис Пример» написан верно, и укорачивать имя до
            // «Борис» не за что. Из `table` это слово выпало по другой причине —
            // фамилию делят двое («Marina Primer»), единоличного владельца нет.
            guard parts.contains(where: { $0 != key && zip(key, $0).prefix(while: ==).count >= 4 })
            else { return nil }
        }
        return name == span ? nil : name
    }

    /// Слово с заглавной, до трёх слов подряд — кандидат на имя.
    private static let candidates = try! NSRegularExpression(
        pattern: #"\p{Lu}\p{L}+(?:[  ]\p{Lu}\p{L}+){0,2}"#
    )

    /// Привести имена в конспекте к написанию из состава.
    ///
    /// `roster` — подписи ленты (`RecapDocument.participants`); пустой состав
    /// значит «журнал молчал», и тогда текст не трогается вовсе.
    public static func normalize(
        _ recap: String, roster: [String], transcript: String = ""
    ) -> String {
        let table = table(roster: roster)
        guard !table.isEmpty, !recap.isEmpty else { return recap }
        // Кириллическое имя сильнее ленточного — но только там, где состав это
        // имя знает: ключ, который `table` выбросила как спорный, спорным и
        // остаётся.
        let written = written(roster: roster, transcript: transcript)
            .filter { table[$0.key] != nil }

        var edits: [(range: Range<String.Index>, replacement: String)] = []

        /// Чем это написание заменяется. Латиница уезжает в кириллицу; там, где
        /// латиницы нет ни в тексте, ни в составе, канон уже выполнен —
        /// «Борис Пример» при русском составе не укорачивается до «Борис».
        func planned(_ span: Substring) -> String? {
            let key = fold(String(span))
            let fromRoster = table[key]
            let canon: String?
            if let cyrillic = written[key], hasLatin(String(span)) || hasLatin(fromRoster ?? "") {
                canon = cyrillic
            } else {
                canon = fromRoster
            }
            guard let canon else { return nil }
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
            // Целиком не совпало — пробуем слова внутри: «Марина Primer»
            // против состава «Marina Primer» лечится по слову.
            //
            // **Но только если состав узнаёт каждое слово.** Иначе замена
            // делает мешаный алфавит внутри одного имени: модель написала
            // «Полина Кременец» (обе части кириллицей), состав знает «Polina
            // Kremenets», «Полина» → «Polina» совпало, «Кременец» нет — «ц»
            // сворачивается в `c`, а в составе `ts`, — и в конспект уезжало
            // «Polina Кременец». Один человек в двух алфавитах внутри одного
            // имени, и написали это мы, а не модель: дефект найден владельцем в
            // живом рекапе 2026-08-28. Половина имени, приведённая к составу, —
            // хуже целого имени, не приведённого никуда.
            var planned2: [(range: Range<String.Index>, replacement: String)] = []
            var resolvedAll = true
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
                    planned2.append((index..<end, canon))
                } else if word.count >= 3, table[fold(String(word))] == nil {
                    // Слово, которого состав не знает вовсе. Короткие («и»,
                    // «на») не считаются: они не части имени.
                    resolvedAll = false
                }
                index = end
            }
            if resolvedAll {
                edits.append(contentsOf: planned2)
            } else if let own = spelledItsOwnWay(span, roster: roster, written: written) {
                // Состав не узнал имя целиком, но узнал, о ком речь: модель
                // написала фамилию своим написанием. Тогда человек зовётся
                // личным именем, и это единственное место, где слово уходит.
                edits.append((range, own))
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
