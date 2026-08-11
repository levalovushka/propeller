import Foundation

/// # Одна фраза не имеет права появиться дважды
///
/// На колонках микрофон слышит дальнюю сторону, и из него распознаётся 95–97 %
/// её слов (`docs/ECHO_AND_MIX_EXPERIMENTS.md` §1; замер 2026-08-11 на реальной
/// встрече: 97.5 %). Тогда одна и та же реплика приезжает на экран дважды — один
/// раз как «Собеседник», один раз под именем владельца.
///
/// # Почему не по громкости
///
/// Прежнее правило (`StemDominance`, удалено) сравнивало громкость дорожек:
/// системный стем снят до колонки, микрофон — после комнаты, значит тише.
/// Замер 2026-08-11 по архиву эту посылку опроверг: **собственный голос
/// владельца в его же микрофоне на 4–6 dB тише эха дальней стороны** (0.0203
/// против 0.0332 RMS на `20260811_121526`; 0.0213 против 0.0452 на
/// `20260811_114818`). Громкость тапа задаёт приложение звонка, громкость
/// микрофона — усиление входа; величины несравнимые, и никакое сравнение с
/// запасом здесь не спасает. Литература по эхоподавлению знает это как предел
/// алгоритма Гейгеля: при разнице уровней около 0 dB детектор двойного разговора
/// по энергии ненадёжен.
///
/// # Почему по тексту
///
/// У нас есть то, чего нет у эхоподавителя: **чистая дальняя сторона уже
/// распознана**. Её слова приезжают по системному каналу по построению, а
/// собственные слова владельца в системном стеме отсутствуют — он снят до
/// колонки. Значит вопрос «эхо или своё» — это вопрос «сказано ли это уже
/// дальней стороной», и он решается на том же уровне, где живёт сам дубль: на
/// тексте. Такое правило не зависит ни от громкости колонок, ни от усиления
/// микрофона, ни от комнаты, и **работает в двойном разговоре**: слова владельца
/// — это лишние токены, а не совпадающие.
///
/// Замер порогов (тот же 2026-08-11, `20260811_121526`, окно 120–300 с, слова с
/// таймингами из `gigastt transcribe -f json`): при звучащем референсе правило
/// снимает **94 %** микрофонных групп, и единственная несnятая — настоящая речь
/// владельца поверх чужой («да нормально да да»). Слов владельца не потеряно ни
/// одного.
///
/// # Порядок ответов
///
/// Две сессии отвечают независимо, и какая успеет первой — гонка. Дубль поэтому
/// снимается сразу, как только виден, а вот **решение «это своё» может подождать**:
/// совпадение от новых слов дальней стороны способно только вырасти, значит
/// «пока не похоже» — это не ответ, а «ещё не всё пришло».
///
/// Ждут не все и недолго:
///
/// - Системный стем на отрезке молчал — эху взяться неоткуда, показываем сразу.
///   Спрашивается именно «звучал ли», а не «кто громче»: это про цифровую
///   тишину, а она от усиления не зависит.
/// - Дальняя сторона уже ответила за весь отрезок и сказала другое — показываем
///   сразу.
/// - Иначе ждём `holdSeconds`. Это **не** задержка живой строки на две секунды:
///   ждём мы не распознавания, а ответа сестринской сессии на те же самые кадры,
///   а он приходит примерно тогда же. Секунда с половиной — запас на разброс, и
///   это потолок добавленной задержки для реплик владельца, попавших **поверх**
///   чужой речи. Своя речь в тишине не платит ничем.
///
/// Если ответа так и нет — реплика показывается. Отсутствие замера не есть
/// замер, и это то же правило, по которому живой слой всегда предпочитал
/// показать текст, а не спрятать его.
public struct EchoDedup: Equatable, Sendable {

    /// Насколько шире отрезка искать слова дальней стороны. Движки режут поток
    /// на фразы по-разному, и одна и та же фраза на двух дорожках получает
    /// границы, разъезжающиеся на секунду с лишним.
    public static let padSeconds: Double = 1.5
    /// Похожесть двух слов, при которой они считаются одним. Эхо распознаётся
    /// испорченным — «в формате» приезжает как «в формации», «э-э» как «э-э-э», —
    /// поэтому сравнение нестрогое.
    public static let tokenMatch: Double = 0.6
    /// Доля знаков реплики, объяснённых дальней стороной, при которой это дубль.
    /// Считается по знакам, а не по словам: у испорченного эха появляются
    /// короткие огрызки («ин», «в»), и по словам они весят столько же, сколько
    /// «интеграции».
    public static let duplicateShare: Double = 0.6
    /// Сколько ждать ответа дальней стороны. Не время распознавания (~2 с,
    /// `live.lag_median_s`), а разброс между двумя сессиями, которым скормлены
    /// одни и те же кадры: они отвечают примерно вместе.
    public static let holdSeconds: Double = 1.5
    /// Сколько истории дальней стороны держим. Встреча на восемь часов не имеет
    /// права расти в памяти.
    public static let historySeconds: Double = 60

    /// Реплика, которую можно показывать.
    public struct Line: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    private struct Said: Equatable, Sendable {
        let start: Double
        let end: Double
        let tokens: [String]
    }

    private struct Waiting: Equatable, Sendable {
        let line: Line
        /// Монотонные секунды, когда реплика пришла. Не время встречи: ждём мы
        /// ответа сети, а не звука.
        let since: Double
    }

    private var remote: [Said] = []
    private var waiting: [Waiting] = []
    /// До какой секунды встречи дальняя сторона уже ответила.
    private var answeredUpTo: Double = 0

    public init() {}

    /// Сколько реплик ждёт ответа. Для лога и тестов — по этому числу видно,
    /// что ожидание не превратилось в утечку.
    public var waitingCount: Int { waiting.count }

    // MARK: - Приём

    /// Дальняя сторона сказала своё. Возвращает реплики владельца, которые
    /// теперь можно показать.
    public mutating func remoteSaid(start: Double, end: Double, text: String) -> [Line] {
        let tokens = TranscriptAccuracy.words(in: text)
        if !tokens.isEmpty {
            remote.append(Said(start: start, end: end, tokens: tokens))
            let cutoff = end - Self.historySeconds
            if let first = remote.first, first.end < cutoff {
                remote.removeAll { $0.end < cutoff }
            }
        }
        answeredUpTo = max(answeredUpTo, end)
        return release(at: nil)
    }

    /// Микрофонная реплика.
    ///
    /// - Parameters:
    ///   - farSideAudible: звучал ли системный стем на этом отрезке. Именно
    ///     «звучал», без сравнения громкостей — иначе вернулось бы правило,
    ///     которое замер опроверг.
    ///   - now: монотонные секунды (`ProcessInfo.systemUptime`), от них считается
    ///     ожидание.
    public mutating func ownerSaid(
        start: Double, end: Double, text: String, farSideAudible: Bool, at now: Double
    ) -> [Line] {
        let line = Line(start: start, end: end, text: text)
        // Дальняя сторона молчала — эху взяться неоткуда, ждать нечего.
        guard farSideAudible else { return [line] + release(at: now) }
        // Дубль виден — снимаем сразу, ждать нечего: похожесть от новых слов
        // дальней стороны только вырастет.
        if isDuplicate(line) { return release(at: now) }
        // Не похоже, и дальняя сторона за этот отрезок уже отговорила — значит
        // это своё.
        if answeredUpTo >= end { return [line] + release(at: now) }
        // Не похоже, но её ответ ещё может прийти.
        waiting.append(Waiting(line: line, since: now))
        return release(at: now)
    }

    /// Время прошло. Реплики, прождавшие дольше `holdSeconds`, показываются.
    public mutating func tick(at now: Double) -> [Line] {
        release(at: now)
    }

    /// Всё, что ещё ждёт, — на экран. Запись кончилась или встала на паузу:
    /// ждать больше нечего, а последние слова — те, ради которых смотрят.
    public mutating func flush() -> [Line] {
        let held = waiting.map(\.line)
        waiting.removeAll()
        return held
    }

    public mutating func reset() {
        remote.removeAll()
        waiting.removeAll()
        answeredUpTo = 0
    }

    // MARK: - Решение

    /// Выпустить те, по которым решение уже можно принять. `now == nil` — вызов
    /// пришёл от дальней стороны, и дедлайн тут не при чём.
    private mutating func release(at now: Double?) -> [Line] {
        guard !waiting.isEmpty else { return [] }
        var admitted: [Line] = []
        var stillWaiting: [Waiting] = []
        for item in waiting {
            if isDuplicate(item.line) {
                continue
            } else if answeredUpTo >= item.line.end {
                admitted.append(item.line)
            } else if let now, now - item.since >= Self.holdSeconds {
                // Ответа нет. Отсутствие замера не есть замер — показываем.
                admitted.append(item.line)
            } else {
                stillWaiting.append(item)
            }
        }
        waiting = stillWaiting
        return admitted
    }

    /// Сказала ли это уже дальняя сторона.
    func isDuplicate(_ line: Line) -> Bool {
        let tokens = TranscriptAccuracy.words(in: line.text)
        guard !tokens.isEmpty else { return true }
        let heard = remote
            .filter { $0.end > line.start - Self.padSeconds && $0.start < line.end + Self.padSeconds }
            .flatMap(\.tokens)
        guard !heard.isEmpty else { return false }

        let total = tokens.reduce(0) { $0 + $1.count }
        var explained = 0
        for token in tokens where heard.contains(where: { Self.similar(token, $0) }) {
            explained += token.count
        }
        return Double(explained) / Double(max(total, 1)) >= Self.duplicateShare
    }

    /// Короче этого нестрогое сравнение не применяется.
    ///
    /// При двух-трёх знаках одна правка меняет слово целиком: «ни» → «они», «да»
    /// → «два». Это стоило живой реплики — в харнессе «Понял, до пятницы не
    /// трогаю» приехало как «ни ни ни ни ни юз до пятницы не трогаю», каждое «ни»
    /// сошлось с «они» из речи собеседницы, и вся реплика была снята как эхо
    /// (coverage 0.964 → 0.916). Порог поймал тест, а не встреча.
    static let fuzzyMinimum = 4

    /// Одно и то же слово, распознанное дважды с разным качеством.
    static func similar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        // Протяжное «э-э-э» против «э-э»: движок записывает тянущийся звук разным
        // числом слогов, и это одно и то же слово, а не похожие.
        if lhs.contains("-") || rhs.contains("-") {
            if syllables(lhs) == syllables(rhs) { return true }
        }
        guard min(lhs.count, rhs.count) >= fuzzyMinimum else { return false }
        let longest = max(lhs.count, rhs.count)
        // Разница длин уже больше допуска — расстояние считать незачем.
        if Double(abs(lhs.count - rhs.count)) / Double(longest) > 1 - tokenMatch { return false }
        let distance = editDistance(Array(lhs), Array(rhs))
        return 1 - Double(distance) / Double(longest) >= tokenMatch
    }

    private static func syllables(_ word: String) -> Set<String> {
        Set(word.split(separator: "-").map(String.init))
    }

    /// Левенштейн на двух строках слова. Одна строка памяти: слова короткие, но
    /// вопрос задаётся на каждое слово каждой реплики.
    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
