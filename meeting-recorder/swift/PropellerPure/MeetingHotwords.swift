import Foundation

/// Словарь **одной встречи**: имена участников и название — в подсказки ASR.
///
/// Общий словарь (`BuiltinHotwords`) платит за каждое слово везде, поэтому он
/// короткий и выверенный: короткий термин, похожий на частое обычное слово, —
/// мина («нид» поверх «нет», «эдит» поверх «идёт», сняты 2026-08-12). Словарь
/// встречи так не платит. «Ситдиков» существует только там, где Ситдиков
/// приглашён; на всех остальных встречах его нет вовсе, поэтому ложное
/// срабатывание может случиться ровно там, где слово и правда ожидается.
///
/// Отсюда правила отбора — они консервативнее общего списка не потому, что
/// осторожность приятна, а потому что проверить каждое слово тут некому:
///
/// - **не короче `minimumLength`** — четыре буквы, как в общем списке;
/// - **только кириллица**: подсказка смещает продолжения токенов при жадном
///   декоде, а модель русская, и латиницу она пишет как придётся («spet Yi»
///   вместо Spotify). Латинские названия чинятся после, `TermCanon`;
/// - **из названия — не всё подряд**: «Дом Пряжи» стоит подсказать, «встреча»
///   и «синк» — нет. Слово, которое модель и так пишет верно, не может помочь,
///   а навредить может.
///
/// Почта разбирается отдельно: организатор в EventKit часто приходит адресом,
/// а не именем, и `radik.sitdikov@vkteam.ru` — это «Радик Ситдиков», которого
/// иначе в словаре не будет. Обратная транслитерация угадывает, поэтому берётся
/// только адрес вида `имя.фамилия` (односоставный в этом архиве — инициалы:
/// `ll@`, `pkr@`, `senb@`) и только когда каждая буква разобрана однозначно.
///
/// **Чего тут нет.** Склонений («Радику», «Саше») — генерировать их
/// правилами значит выдумывать слова, которых человек не говорил; смещение
/// работает по продолжениям, так что именительный падеж уже помогает началу.
/// Терминов из прошлых встреч серии (`seriesID`) — они лежат в архиве и это
/// следующий шаг, но у него другая цена: словарь начинает зависеть от того,
/// что модель написала в прошлый раз.
public enum MeetingHotwords {
    /// Короче — не подсказка, а мина: на четырёх буквах одна ошибка декода уже
    /// превращает слово в другое, существующее.
    public static let minimumLength = 4

    /// Больше — это рассылка, а не встреча: имена из такого приглашения
    /// не подсказываются вовсе, кроме организаторского.
    public static let maximumAttendees = 12

    /// Ящики, за которыми нет человека. Без этого списка `info@vkteam.ru`
    /// уезжает в словарь как «Инфо» — слово, которого на встрече не говорят,
    /// зато похожее на «Инфа» и «в фото».
    private static let serviceMailboxes: Set<String> = [
        "info", "mail", "email", "admin", "support", "help", "sales", "team",
        "hello", "contact", "office", "noreply", "reply", "service", "billing",
        "account", "accounts", "notifications", "calendar", "invite", "invites",
        "events", "meet", "meeting", "marketing", "press", "security", "abuse",
        "webmaster", "postmaster", "robot", "bot", "test",
    ]

    /// Слова названия, которые есть на каждой второй встрече. Подсказывать их
    /// нечего: модель их и так пишет, а вес они займут.
    private static let titleStopwords: Set<String> = [
        "встреча", "встречи", "созвон", "звонок", "дейлик", "дейлики",
        "синк", "синка", "митап", "обсуждение", "обсуждаем", "запись",
        "оценка", "оценки", "проект", "проекта", "работа", "работы",
        "статус", "статусы", "планёрка", "планерка", "ретро", "демо",
        "интервью", "собес", "созвониться", "поговорим", "разбор",
        "синхронизация", "синхрон", "апдейт", "статус-встреча",
    ]

    /// Подсказки для встречи. Порядок — имена, потом название: если список
    /// когда-нибудь придётся резать, резать надо с конца.
    public static func terms(for meta: CalendarMeta?) -> [String] {
        guard let meta, !meta.isEmpty else { return [] }

        var out: [String] = []
        var seen = Set<String>()

        func add(_ phrase: String) {
            let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= minimumLength, isCyrillic(clean) else { return }
            guard seen.insert(clean.lowercased()).inserted else { return }
            out.append(clean)
        }

        // Рассылка — не встреча. На «Агентном дизайне» в приглашении 107
        // адресов, говорят четверо, и подсказать сто имён значит подсказать
        // девяносто шесть лишних.
        let people = meta.attendees.count > maximumAttendees
            ? [meta.organizer].compactMap { $0 }
            : [meta.organizer].compactMap { $0 } + meta.attendees
        for person in people {
            for phrase in namePhrases(person) { add(phrase) }
        }
        for word in titleTerms(meta.title) { add(word) }
        return out
    }

    // MARK: - Люди

    /// Имя целиком плюс каждая его часть: в разговоре зовут и «Радик Ситдиков»,
    /// и просто «Радик».
    static func namePhrases(_ raw: String) -> [String] {
        let name = raw.contains("@") ? nameFromEmail(raw) : raw
        guard let name, !name.isEmpty else { return [] }

        let parts = name
            .split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
            .map(String.init)
            .filter { $0.count >= minimumLength }
        guard !parts.isEmpty else { return [] }
        return parts.count > 1 ? [parts.joined(separator: " ")] + parts : parts
    }

    /// `radik.sitdikov@vkteam.ru` → «Радик Ситдиков».
    ///
    /// Только `имя.фамилия`: два слова из букв через точку, дефис или
    /// подчёркивание. `info@`, `no-reply@`, `levon+work@`, `ll@` — не имена.
    public static func nameFromEmail(_ address: String) -> String? {
        guard let local = address.split(separator: "@").first.map(String.init),
              !local.isEmpty else { return nil }

        let chunks = local
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
            .map { $0.lowercased() }
        // **Только `имя.фамилия`.** Односоставный адрес в этом архиве почти
        // всегда инициалы или сокращение — `ll@`, `pkr@`, `ash@`, `senb@`, — и
        // транслитерация делает из них слова, которых нет: «Арсм», «Сенб»,
        // «Мкаб». Проверено сухим прогоном по 26 встречам с календарём.
        guard chunks.count == 2 else { return nil }
        guard chunks.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return nil }
        guard !chunks.contains(where: serviceMailboxes.contains) else { return nil }

        var words: [String] = []
        for chunk in chunks {
            // Инициал вместо имени (`i.sarkisova`) — не слово; фамилии хватит.
            if chunk.count < 3 { continue }
            // Кириллица в адресе — редкость, но тогда транслитерировать нечего.
            guard let word = isCyrillic(chunk) ? chunk : transliterate(chunk),
                  word.count >= minimumLength else { return nil }
            words.append(word.capitalizedFirst)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Латиница → кириллица по обычным для русских имён соответствиям.
    ///
    /// `nil` в двух случаях, и оба — про вред. Первый: встретилась буква не из
    /// таблицы. Второй: `y` стоит там, где по-русски может быть и «ы», и «й», и
    /// «ий» (`dmitry`, `yuriy`). Неверная подсказка не просто бесполезна — она
    /// смещает декод к написанию, которого нет: без неё модель пишет
    /// «Алексей» сама, а с «алексеы» может написать «алексеы».
    public static func transliterate(_ latin: String) -> String? {
        guard !hasAmbiguousY(latin) else { return nil }
        // Хвосты женских и мужских имён: `yulia` — «Юлия», а не «Юлиа»,
        // `dmitrii` — «Дмитрий», а не «Дмитрии».
        var latin = latin
        if latin.count > 3, latin.hasSuffix("ia") { latin = latin.dropLast(2) + "iya" }
        if latin.count > 3, latin.hasSuffix("ii") { latin = latin.dropLast(2) + "iy" }
        // Диграфы раньше одиночных букв, иначе «sh» станет «сх».
        let pairs: [(String, String)] = [
            ("iya", "ия"), ("shch", "щ"), ("sch", "щ"), ("zh", "ж"), ("kh", "х"), ("ts", "ц"),
            ("ch", "ч"), ("sh", "ш"), ("yu", "ю"), ("ya", "я"), ("yo", "ё"),
            ("ye", "е"), ("iy", "ий"), ("ij", "ий"),
            ("ey", "ей"), ("ay", "ай"), ("oy", "ой"), ("uy", "уй"), ("yy", "ый"),
            ("a", "а"), ("b", "б"), ("c", "к"), ("d", "д"), ("e", "е"),
            ("f", "ф"), ("g", "г"), ("h", "х"), ("i", "и"), ("j", "й"),
            ("k", "к"), ("l", "л"), ("m", "м"), ("n", "н"), ("o", "о"),
            ("p", "п"), ("q", "к"), ("r", "р"), ("s", "с"), ("t", "т"),
            ("u", "у"), ("v", "в"), ("w", "в"), ("x", "кс"), ("y", "ы"),
            ("z", "з"),
        ]

        var rest = Substring(latin)
        var out = ""
        outer: while !rest.isEmpty {
            for (latinPart, cyrillic) in pairs where rest.hasPrefix(latinPart) {
                out += cyrillic
                rest = rest.dropFirst(latinPart.count)
                continue outer
            }
            return nil
        }
        return out
    }

    // MARK: - Название

    /// Слова названия, которые стоит подсказать: имена собственные проектов и
    /// клиентов («Пряжи», «Камуфляж»), а не «дейлик» и не «оценка».
    ///
    /// Отбор по заглавной букве, и это не эстетика: в сухом прогоне по архиву
    /// строчные слова названий оказались обычными русскими — «регулярный»,
    /// «синхронизация», «знакомство», «косметика». Модель пишет их и так,
    /// значит подсказка может только навредить.
    static func titleTerms(_ title: String) -> [String] {
        title
            .split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .map(String.init)
            .filter { $0.count >= 5 }
            .filter { $0.first?.isUppercase == true }
            .filter { !titleStopwords.contains($0.lowercased()) }
    }

    // MARK: - Мелочи

    /// `y`, которую таблица разобрать не может: не в связке с гласной и не
    /// после гласной. `alexey` — можно («ей»), `dmitry` — нельзя («дмитрый»
    /// или «дмитрий», по написанию не видно).
    private static func hasAmbiguousY(_ latin: String) -> Bool {
        let safeBefore = Set("aeiou")           // ya, yu, yo, ye
        let safeAfter = Set("aeiou")            // ey, ay, oy, uy, iy
        let letters = Array(latin)
        for (index, letter) in letters.enumerated() where letter == "y" {
            let next = index + 1 < letters.count ? letters[index + 1] : " "
            let previous = index > 0 ? letters[index - 1] : " "
            if safeBefore.contains(next) || safeAfter.contains(previous) { continue }
            return true
        }
        return false
    }

    static func isCyrillic(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { ("а"..."я").contains(Character($0.properties.lowercaseMapping))
            || Character($0.properties.lowercaseMapping) == "ё" }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
