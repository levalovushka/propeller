import Foundation

/// Лента готовой встречи, собранная из двух дорожек.
///
/// # Что здесь решается
///
/// Микрофонный стем снят до колонки: всё, что в нём осталось после снятия эха,
/// произнёс владелец — это свойство записи, а не оценка. Системный стем снят до
/// микрофона: владельца в нём нет вовсе. Значит одну границу говорящих из двух
/// можно не угадывать диаризацией, а знать. `StemMerge` собирает из двух списков
/// одну ленту; этот файл отвечает на предыдущий вопрос — **какие микрофонные
/// слова принадлежат владельцу**.
///
/// # Почему эхо снимается по словам, а не по репликам
///
/// `EchoDedup` (живой слой) решает про реплику целиком: доля знаков,
/// объяснённых дальней стороной, либо больше `duplicateShare`, либо нет. На
/// колонках этого не хватает в обе стороны, и оба промаха замерены на встрече
/// тестировщика (17 минут, колонки, 2080 микрофонных слов):
///
/// - **Эхо остаётся.** Сегмент, где половина слов свои, а половина эхо, не
///   дотягивает до порога и приезжает целиком: «кожаный, да, я видел. Ну, это,
///   на самом деле,» — вторая половина сказана собеседницей. Таких строк в
///   собранной ленте было 26 из 122, то есть 10.4 % слов против 9.9 % у микса:
///   склейка дорожек сама по себе путаницу **не убирает**, вопреки «нулю по
///   построению» — ASR режет микрофон не по границам чужой речи.
/// - **Своё пропадает.** Реплика, где эха больше порога, снимается вся, вместе
///   со словами владельца внутри неё. Цена замерена: построчный проход поверх
///   пословового выбрасывает 142 слова владельца из 773 (18 %) ради двух чужих
///   слов из семнадцати.
///
/// Поэтому, когда у слов есть тайминги, эхо снимается послововно, а построчный
/// проход остаётся запасным путём — на случай, когда таймингов нет.
///
/// # Почему тайминги, а не номер слова в реплике
///
/// Заход считать время слова по его номеру внутри реплики сделал хуже: чужих
/// слов в репликах владельца осталось 7.9 % против 4.3 % у грубого окна на весь
/// сегмент. Причина в длинных сегментах — один системный сегмент этой встречи
/// занимает 08:28–09:48, восемьдесят секунд, и линейная доля внутри него врёт на
/// секунды. Сайдкар отдаёт время каждого слова (`segments[].words`), и спрашивать
/// надо его.
public enum StemAssembly {

    /// Насколько может разъехаться время одного и того же слова на двух
    /// дорожках.
    ///
    /// Дорожки снимаются одной IOProc и совпадают кадр в кадр
    /// (`ProcessTapCapture`), а путь колонка → комната → микрофон — единицы
    /// миллисекунд. Разъезжаются не звуки, а тайминги ASR. Замер на встрече
    /// тестировщика: **80 % совпавших слов укладываются в 0.04 с, 95 % — в
    /// 0.12 с**; окно 0.3 с покрывает 97.4 % совпадений, 0.5 с — 98.0 %, дальше
    /// прибавка уходит в хвост около двух секунд, а это уже не эхо, а то же
    /// слово, сказанное в другой момент. Полсекунды — вчетверо больше разброса и
    /// втрое меньше того хвоста.
    public static let echoWindow: Double = 0.5

    /// Собрать ленту встречи из двух дорожек.
    ///
    /// - Parameters:
    ///   - mic: микрофонные реплики как их распознал ASR — **с эхом**.
    ///   - micWords: те же слова с таймингами. Пусто — работает запасной путь.
    ///   - ownerName: чьи это слова. Имя владельца, а не «Speaker N»: на
    ///     микрофонной дорожке после снятия эха других людей нет по построению.
    ///   - farSide: системная дорожка, где спикеров уже расставила диаризация.
    ///   - farWords: её слова с таймингами.
    ///
    /// Единственная точка входа: и приложение, и замерный драйвер собирают ленту
    /// этой функцией. Драйвер, считающий что-то своё, измеряет не продукт.
    public static func assemble(
        mic: [EchoDedup.Line],
        micWords: [ASRWord] = [],
        ownerName: String,
        farSide: [StemMerge.Line],
        farWords: [ASRWord] = [],
        window: Double = echoWindow
    ) -> [StemMerge.Line] {
        let heard = farSide.map { EchoDedup.Line(start: $0.start, end: $0.end, text: $0.text) }
        let owner = ownerLines(
            mic: mic, micWords: micWords, farSide: heard, farWords: farWords, window: window
        ).map {
            StemMerge.Line(start: $0.start, end: $0.end, speaker: ownerName, text: $0.text)
        }
        return StemMerge.merge(owner: owner, others: farSide)
    }

    /// Микрофонные слова, которых дальняя сторона не говорила.
    public static func ownerLines(
        mic: [EchoDedup.Line],
        micWords: [ASRWord] = [],
        farSide: [EchoDedup.Line],
        farWords: [ASRWord] = [],
        window: Double = echoWindow
    ) -> [EchoDedup.Line] {
        guard !mic.isEmpty else { return [] }
        // Дальней стороны нет — эху взяться неоткуда (запись только с
        // микрофона, встреча вживую). Снимать нечего.
        guard !farSide.isEmpty else { return mic }
        guard !micWords.isEmpty, !farWords.isEmpty else {
            return lineLevelOwnerLines(mic: mic, farSide: farSide)
        }
        return mic
            .flatMap { withoutEcho($0, words: micWords, farWords: farWords, window: window) }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    // MARK: - Послововое снятие

    /// Убрать из реплики слова, сказанные дальней стороной в то же время.
    ///
    /// # Почему реплика рвётся, а не обрезается по краям
    ///
    /// Эхо стоит не только на краях: собеседник вставляет слово в середину
    /// чужой фразы, и ASR кладёт всё это в один сегмент. Вынуть середину и
    /// склеить края — значит написать предложение, которого никто не говорил.
    /// Поэтому сегмент распадается на серии своих слов, а на месте вынутого эха
    /// в ленте стоит реплика дальней стороны — та самая, из которой это эхо и
    /// взялось. Порядок разговора сохраняется, и `StemMerge` не сольёт серии
    /// обратно: между ними говорил другой человек.
    ///
    /// Слов нет (старый сайдкар, пустой ответ) — реплика остаётся как есть.
    /// Отсутствие замера не есть замер: это то же правило, по которому живой
    /// слой предпочитает показать текст, а не спрятать его.
    static func withoutEcho(
        _ line: EchoDedup.Line,
        words: [ASRWord],
        farWords: [ASRWord],
        window: Double = echoWindow
    ) -> [EchoDedup.Line] {
        let own = words.filter { $0.middle >= line.start && $0.middle <= line.end }
        guard own.count > 1, !farWords.isEmpty else { return [line] }

        var runs: [[ASRWord]] = []
        var current: [ASRWord] = []
        for word in own {
            if isEcho(word, farWords: farWords, window: window) {
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { runs.append(current) }

        // Ни одного слова эха — реплика возвращается своим текстом, со знаками
        // препинания и заглавными, как её отдал ASR.
        if runs.count == 1, runs[0].count == own.count { return [line] }

        return runs.compactMap { run in
            let text = run.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !TranscriptAccuracy.words(in: text).isEmpty else { return nil }
            return EchoDedup.Line(start: run[0].start, end: run[run.count - 1].end, text: text)
        }
    }

    /// Сказала ли дальняя сторона это самое слово в это самое время.
    ///
    /// Сравниваются середины слов: границы одного и того же слова на двух
    /// дорожках разъезжаются, середина — нет. Похожесть — та же нестрогая, что у
    /// живого слоя (`EchoDedup.similar`): эхо распознаётся испорченным, «в
    /// формате» приезжает как «в формации».
    private static func isEcho(_ word: ASRWord, farWords: [ASRWord], window: Double) -> Bool {
        guard let token = TranscriptAccuracy.words(in: word.text).first else {
            // В слове нет ни букв, ни цифр — свидетельства ни за, ни против;
            // рвать серию из-за одинокой запятой незачем.
            return false
        }
        return farWords.contains {
            abs($0.middle - word.middle) <= window
                && EchoDedup.similar(token, TranscriptAccuracy.words(in: $0.text).first ?? "")
        }
    }

    // MARK: - Запасной путь: построчно

    /// Снять эхо построчно — тем же кодом, которым это делает живой слой.
    ///
    /// Работает, когда таймингов слов нет. Порядок подачи — по времени встречи,
    /// и это не деталь реализации: `EchoDedup.historySeconds` держит минуту
    /// истории, поэтому «сначала вся дальняя сторона, потом весь микрофон»
    /// оставило бы к первой микрофонной реплике только конец встречи, и эхо
    /// начала приехало бы второй строкой под именем владельца.
    ///
    /// Логика дедупа не переписывается: иначе офлайн и живой транскрипт начали
    /// бы расходиться в том, кто что сказал.
    private static func lineLevelOwnerLines(
        mic: [EchoDedup.Line],
        farSide: [EchoDedup.Line]
    ) -> [EchoDedup.Line] {
        var events: [(line: EchoDedup.Line, isOwner: Bool)] =
            farSide.map { ($0, false) } + mic.map { ($0, true) }
        events.sort {
            ($0.line.start, $0.isOwner ? 1 : 0, $0.line.end)
                < ($1.line.start, $1.isOwner ? 1 : 0, $1.line.end)
        }

        var dedup = EchoDedup()
        var out: [EchoDedup.Line] = []
        for event in events {
            let line = event.line
            if event.isOwner {
                out += dedup.ownerSaid(
                    start: line.start,
                    end: line.end,
                    text: line.text,
                    // Живой слой спрашивает у звука, звучал ли системный стем
                    // (цифровая тишина, `FeedGate`). Здесь звука нет, есть
                    // распознанный текст, и вопрос задаётся ему — тем же окном,
                    // которым дедуп ищет слова эха. Там, где в окне нет ни
                    // одного слова дальней стороны, дубля не может быть ни по
                    // звуку, ни по тексту.
                    farSideAudible: audible(farSide, from: line.start, to: line.end),
                    // Часы здесь — время встречи. В жизни ожидание меряется
                    // монотонными секундами, потому что ждут ответа сети; в
                    // офлайне ждать нечего, и время встречи — точный аналог:
                    // «ответ ещё может прийти» значит «дальняя сторона ещё не
                    // отговорила за этот отрезок».
                    at: line.start
                )
            } else {
                out += dedup.remoteSaid(start: line.start, end: line.end, text: line.text)
            }
        }
        // Встреча кончилась: то, что ещё ждёт ответа, ответа уже не получит.
        let last = events.map(\.line.end).max() ?? 0
        out += dedup.tick(at: last + EchoDedup.holdSeconds)
        out += dedup.flush()
        return out.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Говорила ли дальняя сторона в окне этой реплики.
    private static func audible(_ farSide: [EchoDedup.Line], from start: Double, to end: Double) -> Bool {
        farSide.contains {
            $0.end > start - EchoDedup.padSeconds && $0.start < end + EchoDedup.padSeconds
        }
    }
}
