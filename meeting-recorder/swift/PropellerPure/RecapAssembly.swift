import Foundation

/// # Механическая сборка конспекта из фактов — код, не модель
///
/// Порт стенда `tools/recap-lab/bench_ensemble.py` (items_from_facts · merge ·
/// prose_blocks · merge_prose · render), шаг в шаг: паритет закреплён фикстурами,
/// перенесёнными из `test_parse.py` (RELEASE-1.16.5.md, Г1). Замер A5.1: свод,
/// собранный кодом, не может схлопнуться — в нём нет генерации — и держит
/// 7,7 пункта против 6,9 у свободного свода, теряющего до пяти найденных.
///
/// Чего здесь **нет** по решению (не по забывчивости): фильтра слота исполнителя
/// (`owners.py`) и фильтра артефактов (`strip_artifacts`) — это конструкции
/// ансамбля, срезанного из 1.16.5; их роль в проде играют `RecapLint.grounded`
/// и `TermCanon` дальше по конвейеру. И нет «Итога»: прозу пишет только модель,
/// а этот путь существует ровно потому, что её свод ломался.
public enum RecapAssembly {

    /// Секция конспекта → она же метка экстрактора. Порядок — как в промпте.
    public static let sections = ["Решения", "Задачи", "Открытые вопросы"]
    public static let narrative = "Ход обсуждения"

    static let factLabels: [String: String] = [
        "ДОГОВОРИЛИСЬ": "Решения",
        "ЗАДАЧА": "Задачи",
        "ОТКРЫТО": "Открытые вопросы",
        "ТЕМА": narrative,
    ]

    private static let stopWords: Set<String> = [
        "это", "как", "для", "что", "при", "или", "она", "его", "все", "так", "там",
    ]

    // Метка ищется в строке, с которой сняты маркер буллета и болд: экстрактор
    // пишет и `- ДОГОВОРИЛИСЬ:`, и `**ЗАДАЧА:**`, и двоеточие оказывается то
    // внутри болда, то вне.
    private static let factHead = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s+)?([А-ЯЁ]{4,})\s*:\s*(.*)$"#
    )
    private static let bulletLine = try! NSRegularExpression(pattern: #"^[-*]\s+(.*)$"#)
    private static let timecode = try! NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2})\b"#)
    private static let headingLine = try! NSRegularExpression(pattern: #"^\s*\*\*.+\*\*\s*:?\s*$"#)
    private static let keyWord = try! NSRegularExpression(pattern: #"[а-яa-z]{4,}"#)
    /// Символов от начала строки, где таймкод — это заголовок абзаца, а не срок в теле.
    private static let headerTimecodeLimit = 12

    private static func emptyItems() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for section in sections + [narrative] { out[section] = [] }
        return out
    }

    private static func firstMatch(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    /// Разбор форм, в которых экстрактор пишет один и тот же размеченный список.
    ///
    /// Он выдаёт то `ДОГОВОРИЛИСЬ: раз; два; три` одной строкой, то
    /// `ДОГОВОРИЛИСЬ:` и буллеты следом, то строку-продолжение без маркера, то
    /// `- ДОГОВОРИЛИСЬ: раз; два` — метку внутри буллета. Этот разбор ломался
    /// **четырежды**, каждый раз новой формой; формы закреплены фикстурами.
    /// Правило из аудита: метка ищется после снятия маркера буллета и болда, и
    /// строка с меткой не попадает в конспект дословно ни при какой форме.
    /// Метка вне четырёх секцию не переключает, но и в документ не едет:
    /// остаётся тело без ярлыка.
    public static func itemsFromFacts(_ facts: String) -> [String: [String]] {
        var out = emptyItems()
        var current: String?
        for raw in facts.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.uppercased().hasPrefix("ПУСТО") { continue }
            let unbolded = line.replacingOccurrences(of: "**", with: "")
            if let head = firstMatch(factHead, unbolded),
               let label = group(head, 1, in: unbolded)?.uppercased() {
                if let target = factLabels[label] ?? current {
                    current = target
                    // «раз; два; три» — три пункта, а не один: точка с запятой —
                    // разделитель списка, экстрактору так велено промптом.
                    let body = group(head, 2, in: unbolded) ?? ""
                    out[target, default: []] += body.split(separator: ";")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.count > 15 }
                }
                continue
            }
            if let bullet = firstMatch(bulletLine, line) {
                if let current {
                    out[current, default: []].append(
                        (group(bullet, 1, in: line) ?? "").trimmingCharacters(in: .whitespaces)
                    )
                }
                continue
            }
            if let current {
                out[current, default: []].append(line)
            }
        }
        return out
    }

    static func keyWords(_ text: String) -> Set<String> {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let range = NSRange(lowered.startIndex..., in: lowered)
        let words = keyWord.matches(in: lowered, range: range).compactMap { match in
            Range(match.range, in: lowered).map { String(lowered[$0]) }
        }
        return Set(words).subtracting(stopWords)
    }

    /// Один и тот же пункт разными словами? Порог 0,55 по пересечению значимых
    /// слов — шипнутая точка стенда; агрессивнее нельзя («дубль лучше пропуска»).
    static func same(_ a: String, _ b: String, threshold: Double = 0.55) -> Bool {
        let wa = keyWords(a), wb = keyWords(b)
        if wa.isEmpty || wb.isEmpty { return false }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= threshold
    }

    /// Слияние без модели: дубль отбрасывается, из двух формулировок остаётся
    /// длинная — она обычно несёт и срок, и исполнителя.
    public static func merge(_ branches: [[String: [String]]]) -> [String: [String]] {
        var out = emptyItems()
        for section in sections + [narrative] {
            for branch in branches {
                for item in branch[section] ?? [] {
                    if let index = out[section]?.firstIndex(where: { same(item, $0) }) {
                        if item.count > out[section]![index].count {
                            out[section]![index] = item
                        }
                    } else {
                        out[section]?.append(item)
                    }
                }
            }
        }
        return out
    }

    /// Начинает ли строка новый абзац «Хода обсуждения»: таймкод в первых 12
    /// символах (`**00:15 – 06:28**: текст`) или отдельная болд-строка
    /// (`**Тема (05:14 – 12:13)**`). Таймкод в глубине длинной строки —
    /// это срок в теле, не заголовок: по нему абзац отрывался от своего
    /// заголовка и уезжал в другое место хронологии.
    static func blockHead(_ line: String) -> Bool {
        guard let found = firstMatch(timecode, line) else { return false }
        return found.range.location <= headerTimecodeLimit
            || firstMatch(headingLine, line) != nil
    }

    /// Абзацы — блоки, а не строки: строка, не начинающая абзац, продолжает
    /// предыдущий, иначе пересортировка рвёт заголовок от тела.
    static func proseBlocks(_ lines: [String]) -> [String] {
        var blocks: [String] = []
        for line in lines {
            if blockHead(line) || blocks.isEmpty {
                blocks.append(line)
            } else {
                blocks[blocks.count - 1] += "\n" + line
            }
        }
        return blocks
    }

    /// Интервал блока — из его **заголовка**: первая строка, первые два таймкода.
    /// Не min/max по всему блоку: в теле стоят сроки («завтра в 12:30»), и по
    /// ним блок про 20:46 оказывался в начале встречи. Блок без таймкода в
    /// заголовке места в хронологии не занимает — идёт после неё.
    static func blockSpan(_ text: String) -> (start: Int, end: Int)? {
        let head = String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        let range = NSRange(head.startIndex..., in: head)
        let seconds: [Int] = timecode.matches(in: head, range: range).compactMap { match in
            guard let minutes = group(match, 1, in: head).flatMap({ Int($0) }),
                  let secs = group(match, 2, in: head).flatMap({ Int($0) }) else { return nil }
            return minutes * 60 + secs
        }
        guard let start = seconds.first else { return nil }
        return (start, seconds.count > 1 ? max(start, seconds[1]) : start)
    }

    /// «Ход обсуждения» всех ветвей — одна хронология, и **ничего не
    /// выбрасывается**: отбрасывание перекрытого блока стоило 0,87 пункта
    /// покрытия на m2 (разбор в bench_ensemble.merge_prose). Блоки без
    /// таймкода идут после хронологии в порядке ветвей.
    public static func mergeProse(_ branches: [[String: [String]]]) -> [String] {
        var kept: [(span: (start: Int, end: Int)?, text: String)] = []
        for branch in branches {
            for text in proseBlocks(branch[narrative] ?? []) {
                kept.append((blockSpan(text), text))
            }
        }
        let timed = kept.enumerated()
            .compactMap { index, pair in pair.span.map { (span: $0, index: index, text: pair.text) } }
            .sorted {
                // Стабильно, как sorted() в Python: индекс рвёт ничью,
                // иначе паритет с эталоном зависит от прихоти сортировки.
                ($0.span.start, $0.span.end, $0.index) < ($1.span.start, $1.span.end, $1.index)
            }
        return timed.map(\.text) + kept.filter { $0.span == nil }.map(\.text)
    }

    /// Собрать документ из слитых секций. Пустая секция опускается целиком.
    public static func render(_ merged: [String: [String]]) -> String {
        var parts: [String] = []
        for section in sections {
            let items = merged[section] ?? []
            if !items.isEmpty {
                parts.append("## \(section)\n" + items.map { "- \($0)" }.joined(separator: "\n"))
            }
        }
        if let blocks = merged[narrative], !blocks.isEmpty {
            parts.append("## \(narrative)\n" + blocks.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Весь путь одним вызовом: факты фрагментов → конспект. Композиция — как в
    /// эталоне: merge по секциям, проза отдельно хронологией, затем рендер.
    public static func assemble(facts: String) -> String {
        let branch = itemsFromFacts(facts)
        var merged = merge([branch])
        merged[narrative] = mergeProse([branch])
        return render(merged)
    }
}
