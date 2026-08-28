import Foundation

/// # Форма конспекта приводится к канону кодом, а не просьбой к модели
///
/// Четыре правила: голова решения, «Итог» одним абзацем, а в «Задачах» —
/// разметка ответственного и снятые чекбоксы.
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
/// **Снимает чекбоксы.** Решение владельца 2026-08-28: чекбоксов и маркеров нет
/// нигде. Открытый вопрос `plan-projects.md` §4.5 закрыт им же, и закрыт в эту
/// сторону, потому что цена была видна на живом файле: панель саммари не рисует
/// ни заголовок «## Итог», ни маркеры списка, а `[ ]` рисовала **буквально** —
/// «• [ ] дело» у каждой задачи.
///
/// Снимаются только скобки; строка и её слова остаются. Вкладке «Задачи» это не
/// мешает: пункт без скобок — не сделан, и `RecapAtom` ровно так его и читает.
/// Старый архив не трогается — там скобки останутся, и `RecapAtom` их поймёт.
///
/// **Не додумывает состояние.** Задача в прошедшем времени («**Левон** —
/// пересобрал Гант», 12 пунктов архива) — дефект формулировки, а не галочка;
/// это адрес редактору, а не правка здесь.
///
/// **Не трогает секцию «Решения».** У решения нет ни ответственного, ни
/// чекбокса — их там не появляется (`ProjectTab.itemsAreCheckable`).
public enum RecapFormCanon {

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

    /// Привести конспект к канону формы: ответственный в «Задачах» и «Итог»
    /// одним абзацем.
    ///
    /// `roster` — подписи ленты (`RecapDocument.participants`), те же, что
    /// уходят в промпт и в `PersonCanon`.
    public static func canonical(
        _ recap: String, roster: [String], transcript: String = ""
    ) -> Result {
        guard !recap.isEmpty else { return Result(recap: recap, fixed: []) }
        let names = PersonCanon.table(roster: roster)
        let joined = joiningSummary(recap)
        let heads = decisionHeads(in: joined.recap, names: names, fixed: joined.fixed)
        return owners(in: heads.recap, roster: roster, transcript: transcript, fixed: heads.fixed)
    }

    // MARK: - Ответственный

    private static func owners(
        in recap: String, roster: [String], transcript: String, fixed carried: [String]
    ) -> Result {

        let names = PersonCanon.table(roster: roster)
        var fixed = carried
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

            var body = split.body
            if let owner = canonicalOwner(body, names: names, roster: roster, transcript: transcript) {
                fixed.append(owner.quote)
                body = owner.body
            }
            // Чекбокс снимается последним, чтобы разбор ответственного видел
            // строку в том виде, в каком её написала модель.
            if let box = leadingCheckboxEnd(body) {
                fixed.append("чекбокс")
                body = String(body[box...])
            }
            guard body != split.body else { continue }
            lines[index] = split.prefix + body + (carriage ? "\r" : "")
        }
        return Result(recap: lines.joined(separator: "\n"), fixed: fixed)
    }

    // MARK: - Голова решения

    /// Жирного в начале решения не остаётся, и это не косметика: разбор достаёт
    /// из `**Имя** — дело` ответственного, которого у решения быть не может
    /// (`ProjectTab.itemsAreCheckable`), а `**Тема:** пояснение` сообщает
    /// читателю рубрику вместо договорённости.
    ///
    /// Промпт это просит и снимает больше половины (28–29 → 13–21 на корпусе),
    /// адрес редактору снимает ещё часть (13 → 8). Остаток снимается здесь,
    /// потому что снимается знаками.
    ///
    /// # Четыре головы, и только одна теряет слова
    ///
    /// Замер по живому архиву (430 пунктов «Решений», из них 243 с ведущим
    /// жирным, 2026-08-27):
    ///
    /// | что стоит в голове | сколько | что делаем |
    /// |---|---|---|
    /// | рубрика из двух и больше слов | 135 | **снимаем ярлык целиком** |
    /// | однословная рубрика («Сроки:») | 49 | снимаем только звёздочки |
    /// | сущность: имя, проект, латиница, цифры | 28 | снимаем только звёздочки |
    /// | `**Имя** — дело` — форма поручения | 30 | снимаем только звёздочки |
    ///
    /// **Ярлык — единственное место во всём модуле, где слова уходят**, поэтому
    /// заслонок четыре, и каждая из них — про цену ошибки:
    ///
    /// - **проперные слова не трогаем.** Заглавная внутри, латиница или цифра
    ///   значит, что ярлык называет проект или человека: «**ГПН (Дом пряжи)**:
    ///   Проект прокинут…» без головы теряет, о каком проекте речь;
    /// - **однословный ярлык не трогаем.** «Сроки» и «Ирина» с этой стороны
    ///   выглядят одинаково, а цена ошибки перевёрнута: потерять человека хуже,
    ///   чем оставить рубрику. Он просто перестаёт быть заголовком;
    /// - **имя из состава не трогаем** никогда, даже двухсловное;
    /// - **остаток короче пяти слов не трогаем.** «**Сроки:** к сентябрю» без
    ///   головы становится обрывком «К сентябрю», а это хуже рубрики.
    ///
    /// Снятый ярлык уезжает в `fixed` — как и всё остальное, что этот модуль
    /// переписал в чужом тексте.
    private static func decisionHeads(
        in recap: String, names: [String: String], fixed carried: [String]
    ) -> Result {
        var lines = recap.components(separatedBy: "\n")
        var fixed = carried
        var inDecisions = false

        for index in lines.indices {
            let carriage = lines[index].hasSuffix("\r")
            let line = carriage ? String(lines[index].dropLast()) : lines[index]

            if let heading = RecapDigest.headingTitle(
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            ) {
                inDecisions = RecapDigest.foldTitle(heading)
                    == RecapDigest.foldTitle(RecapDigest.decisionsTitle)
                continue
            }
            guard inDecisions, let split = bullet(line),
                  let head = boldHead(split.body)
            else { continue }

            let body: String
            if dropsLabel(head, names: names) {
                fixed.append("ярлык «\(head.label)»")
                body = capitalizingFirst(head.rest)
            } else {
                fixed.append("жирное в решении «\(head.label)»")
                body = head.label + head.separator + head.rest
            }
            lines[index] = split.prefix + body + (carriage ? "\r" : "")
        }
        return Result(recap: lines.joined(separator: "\n"), fixed: fixed)
    }

    /// Ведущее жирное пункта, разобранное на ярлык, разделитель и остаток.
    /// Двоеточие бывает и внутри звёздочек, и снаружи — обе постановки живут в
    /// архиве, и различать их незачем.
    private static func boldHead(
        _ item: String
    ) -> (label: String, separator: String, rest: String)? {
        guard item.hasPrefix("**"),
              let closing = item.range(
                  of: "**", range: item.index(item.startIndex, offsetBy: 2)..<item.endIndex
              )
        else { return nil }
        var label = String(item[item.index(item.startIndex, offsetBy: 2)..<closing.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        var inner = false
        while label.hasSuffix(":") {
            label = String(label.dropLast()).trimmingCharacters(in: .whitespaces)
            inner = true
        }
        guard !label.isEmpty else { return nil }

        var rest = Substring(item[closing.upperBound...])
        var separator = inner ? ": " : ""
        while rest.first == " " { rest = rest.dropFirst() }
        for mark in [":", "—", "–"] where rest.hasPrefix(mark) {
            rest = rest.dropFirst(mark.count)
            separator = mark == ":" ? ": " : " \(mark) "
            while rest.first == " " { rest = rest.dropFirst() }
            break
        }
        if separator.isEmpty { separator = " " }
        let tail = String(rest).trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }
        return (label, separator, tail)
    }

    /// Уходит ли ярлык целиком. Все четыре заслонки — в доке к `decisionHeads`.
    private static func dropsLabel(
        _ head: (label: String, separator: String, rest: String), names: [String: String]
    ) -> Bool {
        guard head.separator.hasPrefix(":") else { return false }
        guard names[PersonCanon.fold(head.label)] == nil else { return false }
        let words = head.label.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
        guard words.count >= 2 else { return false }
        guard head.rest.split(whereSeparator: \.isWhitespace).count >= 5 else { return false }
        // Заглавная **где угодно после первой буквы** — а не после первого
        // слова: «ГПН (Дом пряжи)» пряталась за открывающей скобкой, потому что
        // проверка смотрела на первый символ слова, а не на буквы.
        // Заодно это ловит аббревиатуры целиком.
        var seenLetter = false
        for character in head.label {
            if character.isNumber { return false }
            if character.isASCII, character.isLetter { return false }
            guard character.isLetter else { continue }
            if seenLetter, character.isUppercase { return false }
            seenLetter = true
        }
        return true
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + String(text.dropFirst())
    }

    // MARK: - «Итог» одним абзацем

    /// Ведущий раздел — это **описание встречи под её названием**, а не первая
    /// глава конспекта: панель саммари заголовок «## Итог» не рисует вовсе
    /// (`SummaryDocument.leadHeading`), и второй абзац читается как оборванное
    /// начало текста, которого дальше нет.
    ///
    /// Решение владельца 2026-08-27: ровно один абзац. В живом архиве их больше
    /// одного у 17 конспектов из 139, а у одного — четыре.
    ///
    /// Склейка, а не обрезка: **ни одного слова не теряется**, абзацы
    /// соединяются пробелом. Просить об этом модель мало — она слушается
    /// непоследовательно, и то же правило уже стоит в промпте; здесь оно
    /// гарантируется.
    ///
    /// Список внутри «Итога» останавливает правило целиком: склеить пункты в
    /// абзац — это уже переписывание, а не форматирование.
    private static func joiningSummary(_ recap: String) -> Result {
        var lines = recap.components(separatedBy: "\n")
        guard let section = summarySection(in: lines) else { return Result(recap: recap, fixed: []) }

        var paragraphs: [String] = []
        var current: [String] = []
        for index in section {
            let carriage = lines[index].hasSuffix("\r")
            let line = (carriage ? String(lines[index].dropLast()) : lines[index])
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
                continue
            }
            // Пункт списка или вложенный заголовок — не наш случай.
            if bullet(line) != nil || line.hasPrefix("#") { return Result(recap: recap, fixed: []) }
            current.append(line)
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        guard paragraphs.count > 1 else { return Result(recap: recap, fixed: []) }

        // Заменяется только то, на чём стоит текст: пустые строки до первого
        // абзаца и после последнего остаются на месте. Иначе документ терял бы
        // то пустую строку под заголовком, то перевод строки в конце файла —
        // и вторая правка чужого файла была бы платой за первую.
        guard let first = section.first(where: { !isBlank(lines[$0]) }),
              let last = section.reversed().first(where: { !isBlank(lines[$0]) })
        else { return Result(recap: recap, fixed: []) }
        let carriage = lines[first].hasSuffix("\r") ? "\r" : ""
        lines.replaceSubrange(first...last, with: [paragraphs.joined(separator: " ") + carriage])
        return Result(
            recap: lines.joined(separator: "\n"),
            fixed: ["«Итог» из \(paragraphs.count) абзацев"]
        )
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Строки ведущего раздела — от строки под его заголовком до следующего
    /// `##` или конца. Имена — те же, что у `SummaryDocument.leadHeadings`.
    private static func summarySection(in lines: [String]) -> Range<Int>? {
        var start: Int?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let heading = RecapDigest.headingTitle(line) else { continue }
            if start != nil { return start! ..< index }
            let folded = RecapDigest.foldTitle(heading)
            if ["итог", "итоги", "summary"].contains(folded) { start = index + 1 }
        }
        guard let start, start < lines.count else { return nil }
        return start ..< lines.count
    }

    // MARK: - Ответственный

    /// Пункт с ответственным в канонической разметке — или `nil`, если чинить
    /// нечего и если чинить нечем.
    private static func canonicalOwner(
        _ item: String, names: [String: String], roster: [String], transcript: String
    ) -> (body: String, quote: String)? {
        guard !names.isEmpty else { return nil }

        let boxEnd = leadingCheckboxEnd(item)
        let box = boxEnd.map { String(item[item.startIndex..<$0]) } ?? ""
        var rest = boxEnd.map { String(item[$0...]) } ?? item
        let leading = rest.prefix(while: { $0 == " " })
        rest = String(rest.dropFirst(leading.count))

        guard let owner = ownerHead(rest) else { return nil }
        // Человек ли это — спрашивается **в одном месте**: у состава. Он же
        // отвечает, каким написанием этого человека звать. Ничего не изменилось —
        // это увидит сравнение собранной строки ниже, а не запасная таблица.
        guard let person = assigneeName(owner.name, roster: roster, transcript: transcript)
        else { return nil }
        let tail = String(rest[owner.end...]).trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }
        let canon = "**\(person)** — " + tail
        guard canon != rest else { return nil }
        return (box + leading + canon, String(rest.prefix(owner.quoteLength)))
    }

    /// Участник состава целиком — по любому его слову, если слово принадлежит
    /// ровно ему одному.
    ///
    /// # Почему в слоте ответственного стоит полное имя
    ///
    /// На одной встрече модель взяла из состава два имени и сделала с ними
    /// противоположное: «Vlad Aldokhin» сократила до «Vlad» и оставила
    /// латиницей, «Polina Kremenets» перевела в кириллицу целиком — «Полина
    /// Кременец», причём слова «Кременец» в транскрипте нет ни разу. Оба
    /// написания прошли `PersonCanon`: первое совпало со словом состава, второе
    /// не разобралось. В документе оказались два человека, названные по двум
    /// разным правилам, и владелец это заметил (2026-08-28).
    ///
    /// Правило было записано давно и не доходило до этого слота: **канон — это
    /// написание из состава** (`PersonCanon`, «читатель конспекта должен найти
    /// этого человека в расшифровке глазами»). Слот ответственного — то место,
    /// где оно обязано выполняться буквально: это не проза, а поле, по которому
    /// задачу связывают с человеком (`RecapAtom.assignee`, чип на экране
    /// проекта, сверка `RecapLint.assigneesOutsideRoster`). Два написания одного
    /// человека здесь стоят дороже длины строки.
    ///
    /// **Проза остаётся как написана.** Там имя стоит в падеже и внутри фразы,
    /// и подстановка полного написания её ломает — то же ограничение, что у
    /// `PersonCanon.normalize`.
    ///
    /// Спорное слово не считается: «Александр» при двух Александрах в составе не
    /// значит ни одного из них (`PersonCanon.soleOwners` возвращает такое слово
    /// пустым), и тогда имя остаётся как написано.
    static func assigneeName(
        _ name: String, roster: [String], transcript: String
    ) -> String? {
        let owners = PersonCanon.soleOwners(roster: roster)
        var entry = owners[PersonCanon.fold(name)]
        if entry == nil {
            // Целиком не совпало — ищем по словам: «Полина Кременец» опознаётся
            // по «Полине», если «Кременец» состав не знает.
            for word in PersonCanon.words(of: name) {
                guard let owner = owners[PersonCanon.fold(word)] else { continue }
                if let entry, entry != owner { return nil }   // два человека в одном имени
                entry = owner
            }
        }
        guard let entry else { return nil }
        // Возвращается **всегда**, даже когда совпало с написанным: «ничего не
        // менять» и «это не человек» — разные ответы, и различать их обязан этот
        // метод. Раньше он на совпадении отдавал `nil`, вызывающий шёл в
        // запасную таблицу и получал оттуда **слово состава** — то есть «Марина»
        // превращалась в «Marina» ровно там, где менять было нечего.
        return personal(of: entry, roster: roster, transcript: transcript) ?? entry
    }

    /// Кириллическое личное имя участника — или `nil`, и тогда зовут по составу
    /// целиком.
    ///
    /// # Три условия, и каждое снимает свой способ соврать
    ///
    /// 1. **Личное имя принадлежит одному участнику.** Двое Александров — и
    ///    «Александр» не значит ни одного из них (`PersonCanon.soleOwners`).
    /// 2. **Транслитерация точная.** Обратная схема — инверсия `translit`
    ///    (`PersonCanon.cyrillic`), и её результат обязан свернуться в то же, что
    ///    исходник, иначе имя станет «исполнителем вне состава» для линтера.
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
    /// нечем, а угадать чужую фамилию дороже, чем звать человека полным
    /// написанием из состава.
    static func personal(
        of entry: String, roster: [String], transcript: String
    ) -> String? {
        guard let first = PersonCanon.words(of: entry).first else { return nil }
        // Личное имя должно принадлежать этому участнику одному.
        guard PersonCanon.soleOwners(roster: roster)[PersonCanon.fold(first)] == entry
        else { return nil }

        if first.unicodeScalars.allSatisfy({ !($0.value < 128 && CharacterSet.letters.contains($0)) }) {
            return first   // состав и так по-русски: «Левон», «Анастасия»
        }
        guard let cyrillic = PersonCanon.cyrillic(first),
              attested(cyrillic, in: transcript)
        else { return nil }
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

    /// Два вида, которыми модель пишет ответственного. Оба — строки живого
    /// архива; порядок проверок от самого частого к самому редкому.
    ///
    /// Разбор **не спрашивает, человек ли это**: он только достаёт голову пункта.
    /// Заслонка живёт у вызывающего, у состава, и одна на оба вида.
    ///
    /// Третьего вида — `**Имя** глагол …` совсем без разделителя — здесь нет
    /// сознательно. В архиве таких четыре из 186, а отличить исполнителя от
    /// жирного начала фразы можно только по следующему слову: «**Левон** и Саша
    /// соберут» превратилось бы в «**Левон** — и Саша соберут». Правило, которое
    /// держится на списке союзов, портит текст ради двух процентов пунктов.
    private static func ownerHead(
        _ text: String
    ) -> (name: String, end: String.Index, quoteLength: Int)? {
        // 1. `**Имя**` и любой из четырёх разделителей. Длинное и среднее тире
        //    уже канон по **разметке** — и всё равно разбираются: имя за ними
        //    может стоять не тем написанием, что в составе, и это второе дело
        //    этого слота (`fullName`). Не изменилось ничего — вызывающий вернёт
        //    `nil` сам, сравнив собранную строку с исходной.
        if text.hasPrefix("**"),
           let closing = text.range(
               of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex
           ) {
            let name = String(text[text.index(text.startIndex, offsetBy: 2)..<closing.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            var after = closing.upperBound
            while after < text.endIndex, text[after] == " " { after = text.index(after: after) }
            guard after < text.endIndex, ":-—–".contains(text[after]) else { return nil }
            after = text.index(after: after)
            while after < text.endIndex, text[after] == " " { after = text.index(after: after) }
            return (name, after, text.distance(from: text.startIndex, to: after))
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
              let first = head.first, first.isUppercase
        else { return nil }
        let end = range.upperBound
        return (head, end, text.distance(from: text.startIndex, to: end))
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
