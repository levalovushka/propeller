import Foundation

/// # Насколько распознанный текст похож на то, что было сказано
///
/// Существует ради одного правила: **экономия не имеет права красть слова.**
/// Любая правка, которая делает живой слой дешевле, обязана предъявить, что
/// текст на экране остался тем же — иначе «стало на 20 % эффективнее» означает
/// «стало на 20 % меньше распознавать», и это не оптимизация, а урезание
/// продукта.
///
/// Отсюда три числа, а не одно:
///
/// - **WER** — общая доля ошибок. Растёт от любой порчи, но не говорит, какой.
/// - **`coverage`** — сколько слов эталона вообще доехало. Именно это число
///   ломает гейт, который выключил распознавание в момент речи: WER при этом
///   может даже улучшиться (выброшенное часто и было самым шумным), а речь
///   пропадёт. Ловушка настоящая, поэтому у неё своя метрика.
/// - **`attributionAccuracy`** — доля слов, приписанных верной дорожке. Живой
///   слой раздаёт имена по дорожкам (`LiveTranscript.Channel`), и правка,
///   которая кормит движок избирательно, может дёшево испортить именно это.
///
/// Выравнивание — Левенштейн по словам, а не по символам: пользователь читает
/// слова, и «-ой» вместо «-ый» стоит одну ошибку, а не три.
public struct TranscriptAccuracy {

    /// Слово с дорожки, на которой его услышали. Дорожка необязательна: у
    /// эталона она известна, у стенда без разделения — нет.
    public struct Word: Equatable, Sendable {
        public let text: String
        public let channel: LiveTranscript.Channel?

        public init(text: String, channel: LiveTranscript.Channel? = nil) {
            self.text = text
            self.channel = channel
        }
    }

    public struct Report: Equatable, Sendable {
        public let referenceWords: Int
        public let hypothesisWords: Int
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        /// Сколько слов эталона совпало дословно.
        public let matches: Int
        /// Из совпавших — сколько пришло с той дорожки, что в эталоне.
        /// `nil`, когда дорожек нет ни у эталона, ни у гипотезы.
        public let attributedCorrectly: Int?
        /// Слова эталона, которых в тексте нет вовсе.
        ///
        /// Нужны, чтобы про падение `coverage` можно было спросить «какие
        /// именно» и получить ответ, а не гадать. Разница между «слово
        /// потерялось» и «слово доехало огрызком» — это разница между пропуском
        /// и заменой, и в решении «принимать ли экономию» она главная.
        public let deletedWords: [String]
        /// Пары «сказано → распознано» для слов, которые доехали неверными.
        public let substitutedWords: [(reference: String, hypothesis: String)]

        public static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.referenceWords == rhs.referenceWords
                && lhs.hypothesisWords == rhs.hypothesisWords
                && lhs.substitutions == rhs.substitutions
                && lhs.deletions == rhs.deletions
                && lhs.insertions == rhs.insertions
                && lhs.matches == rhs.matches
                && lhs.attributedCorrectly == rhs.attributedCorrectly
                && lhs.deletedWords == rhs.deletedWords
        }

        /// (S + D + I) / N. Может быть больше 1: вставок бывает сколько угодно.
        public var wer: Double {
            guard referenceWords > 0 else { return hypothesisWords == 0 ? 0 : 1 }
            return Double(substitutions + deletions + insertions) / Double(referenceWords)
        }

        /// Доля слов эталона, доехавших до текста хоть в каком-то виде
        /// (совпадением или заменой). Пропущенное слово — единственное, что её
        /// снижает.
        public var coverage: Double {
            guard referenceWords > 0 else { return 1 }
            return Double(referenceWords - deletions) / Double(referenceWords)
        }

        /// Доля верно подписанных среди дословно совпавших. `nil`, когда
        /// подписывать было нечего.
        public var attributionAccuracy: Double? {
            guard let attributedCorrectly, matches > 0 else { return nil }
            return Double(attributedCorrectly) / Double(matches)
        }
    }

    // MARK: - Нормализация

    /// Текст → слова, приведённые к сравнимому виду: нижний регистр, `ё` → `е`,
    /// без пунктуации. Так считался WER в замере размера порции
    /// (`tools/live-bench/README.md`), и менять правило нельзя — иначе новые
    /// числа не сравнить с теми.
    ///
    /// Дефис внутри слова остаётся («по-моему» — одно слово), одиночный —
    /// исчезает вместе с остальной пунктуацией.
    public static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { $0.isWhitespace })
            .map { chunk -> String in
                String(chunk.unicodeScalars.filter { scalar in
                    let c = Character(scalar)
                    return c.isLetter || c.isNumber || c == "-"
                })
            }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    /// Слова живого транскрипта, каждое со своей дорожкой.
    public static func words(in transcript: LiveTranscript) -> [Word] {
        transcript.turns.flatMap { turn in
            words(in: turn.text).map { Word(text: $0, channel: turn.channel) }
        }
    }

    // MARK: - Сравнение

    public static func compare(hypothesis: [Word], reference: [Word]) -> Report {
        let alignment = align(hypothesis: hypothesis, reference: reference)
        let bothHaveChannels = hypothesis.contains { $0.channel != nil }
            && reference.contains { $0.channel != nil }
        return Report(
            referenceWords: reference.count,
            hypothesisWords: hypothesis.count,
            substitutions: alignment.substitutions,
            deletions: alignment.deletions,
            insertions: alignment.insertions,
            matches: alignment.matches.count,
            attributedCorrectly: bothHaveChannels
                ? alignment.matches.filter { $0.hypothesis.channel == $0.reference.channel }.count
                : nil,
            deletedWords: alignment.deleted.reversed(),
            substitutedWords: alignment.substituted.reversed()
        )
    }

    /// Удобная форма для голого текста — когда дорожки не при чём.
    public static func compare(hypothesis: String, reference: String) -> Report {
        compare(
            hypothesis: words(in: hypothesis).map { Word(text: $0) },
            reference: words(in: reference).map { Word(text: $0) }
        )
    }

    // MARK: - Выравнивание

    struct Alignment {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        /// Пары дословно совпавших слов — по ним считается атрибуция.
        var matches: [(hypothesis: Word, reference: Word)] = []
        var deleted: [String] = []
        var substituted: [(reference: String, hypothesis: String)] = []
    }

    /// Левенштейн по словам с восстановлением пути.
    ///
    /// Матрица направлений хранится байтом на ячейку: часовая встреча — это
    /// порядка 8000 слов на дорожку, то есть десятки мегабайт на прогон стенда.
    /// В приложении этот код не вызывается вовсе — он для замера.
    static func align(hypothesis: [Word], reference: [Word]) -> Alignment {
        let n = reference.count
        let m = hypothesis.count

        var result = Alignment()
        if n == 0 {
            result.insertions = m
            return result
        }
        if m == 0 {
            result.deletions = n
            return result
        }

        enum Move: UInt8 { case diagonal = 0, deletion = 1, insertion = 2 }

        var cost = [Int](repeating: 0, count: (n + 1) * (m + 1))
        var moves = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        let stride = m + 1

        for i in 0...n { cost[i * stride] = i; moves[i * stride] = Move.deletion.rawValue }
        for j in 0...m { cost[j] = j; moves[j] = Move.insertion.rawValue }
        moves[0] = Move.diagonal.rawValue

        for i in 1...n {
            for j in 1...m {
                let same = reference[i - 1].text == hypothesis[j - 1].text
                let diagonal = cost[(i - 1) * stride + (j - 1)] + (same ? 0 : 1)
                let deletion = cost[(i - 1) * stride + j] + 1
                let insertion = cost[i * stride + (j - 1)] + 1

                var best = diagonal
                var move = Move.diagonal
                // Порядок сравнений задаёт, какой путь выбирается при равной
                // цене. Он произволен, но обязан быть постоянным: иначе одно и
                // то же сравнение даёт разные S/D/I между прогонами.
                if deletion < best { best = deletion; move = .deletion }
                if insertion < best { best = insertion; move = .insertion }

                cost[i * stride + j] = best
                moves[i * stride + j] = move.rawValue
            }
        }

        var i = n
        var j = m
        while i > 0 || j > 0 {
            let move = Move(rawValue: moves[i * stride + j]) ?? .diagonal
            switch move {
            case .diagonal:
                guard i > 0, j > 0 else {
                    // Край матрицы: дальше идти можно только по одной оси.
                    if i > 0 { result.deletions += 1; i -= 1 } else { result.insertions += 1; j -= 1 }
                    continue
                }
                if reference[i - 1].text == hypothesis[j - 1].text {
                    result.matches.append((hypothesis[j - 1], reference[i - 1]))
                } else {
                    result.substitutions += 1
                    result.substituted.append(
                        (reference: reference[i - 1].text, hypothesis: hypothesis[j - 1].text)
                    )
                }
                i -= 1
                j -= 1
            case .deletion:
                result.deletions += 1
                result.deleted.append(reference[i - 1].text)
                i -= 1
            case .insertion:
                result.insertions += 1
                j -= 1
            }
        }
        result.matches.reverse()
        return result
    }
}
