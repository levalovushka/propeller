import Foundation

/// # Ссылка на опубликованное саммари
///
/// `https://propeller.report/s/<id>#<slug>&k=<ключ>`
///
/// Всё, что после «#», браузер серверу не отправляет — ни при открытии
/// страницы, ни в `Referer`, ни в логах прокси. Поэтому там живут обе вещи,
/// которых сервер видеть не должен: ключ шифрования и **название встречи**.
///
/// Слаг в пути был бы красивее (`/shared/vstrecha-s-daney/…`), и ровно так
/// просил владелец 2026-08-27. Отменено в тот же день им же: путь — та часть
/// ссылки, которую сервер получает всегда, а название встречи это содержание.
/// «Увольнение Пети» в логе чужой машины стоит дороже, чем красота адреса.
/// Слаг остался — просто переехал за решётку, где он читается человеком и
/// не читается сервером.
public enum ShareLink {

    public static let host = "https://propeller.report"

    /// Собирает ссылку. `slug` — только для глаза: сервис его не получает
    /// и никак на него не смотрит, адресует один `id`.
    public static func url(id: String, key: Data, title: String) -> URL? {
        let slug = slugify(title)
        let k = "k=" + base64url(key)
        let fragment = slug.isEmpty ? k : slug + "&" + k
        return URL(string: "\(host)/s/\(id)#\(fragment)")
    }

    /// Разбор — только для тестов и отладки: в приложении ссылки не читают,
    /// их отдают наружу. Но собранное без разобранного не проверить.
    public static func parse(_ url: URL) -> (id: String, key: Data)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment else { return nil }
        let id = String(components.path.dropFirst("/s/".count))
        guard components.path.hasPrefix("/s/"), id.count == 22 else { return nil }
        for part in fragment.split(separator: "&") where part.hasPrefix("k=") {
            guard let key = data(base64url: String(part.dropFirst(2))) else { return nil }
            return (id, key)
        }
        return nil
    }

    // MARK: - Слаг

    /// Название встречи латиницей: «Встреча с Даней» → `vstrecha-s-daney`.
    ///
    /// Это **не** `MeetingMarkdown.slugify`, и разница не косметическая: тот
    /// делает слаг для имени файла на своей машине и кириллицу сохраняет
    /// как есть. В ссылке кириллица превратилась бы в процентную кашу
    /// (`%D0%92%D1%81%D1%82...`), то есть ровно в то, от чего слаг заводился.
    public static func slugify(_ title: String) -> String {
        var out = ""
        var pendingSeparator = false

        for character in title.lowercased() {
            if let latin = transliterated[character] {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out += latin
            } else if character.isLetter || character.isNumber {
                // Латиница, цифры и всё, что уже годится для адреса, — как есть.
                // Остальные алфавиты (греческий, иврит, эмодзи) сюда не попадают
                // и ведут себя как разделитель: адрес важнее полноты.
                if character.isASCII {
                    if pendingSeparator, !out.isEmpty { out.append("-") }
                    pendingSeparator = false
                    out.append(character)
                } else {
                    pendingSeparator = true
                }
            } else {
                pendingSeparator = true
            }
        }

        return capped(out)
    }

    /// Потолок длины — слаг украшает ссылку, а не переносит её.
    ///
    /// Режется по дефису: обрубок слова в середине читается как опечатка,
    /// а целые слова — как сокращение.
    private static func capped(_ slug: String, limit: Int = 48) -> String {
        guard slug.count > limit else { return slug }
        let head = String(slug.prefix(limit))
        if let lastDash = head.lastIndex(of: "-"), lastDash != head.startIndex {
            return String(head[head.startIndex..<lastDash])
        }
        return head
    }

    /// «ь» и «ъ» отдают пустую строку, а не пропускаются: пропуск сделал бы их
    /// разделителями, и «Пьеса» стала бы `p-esa`.
    private static let transliterated: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        // Украинские и белорусские буквы: имена коллег и названия проектов
        // приходят и на них, а неизвестная буква стала бы дефисом.
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "u",
    ]

    // MARK: - base64url

    /// Без набивки: «=» в адресе пришлось бы кодировать процентами.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if s.count % 4 != 0 { s += String(repeating: "=", count: 4 - s.count % 4) }
        return Data(base64Encoded: s)
    }
}
