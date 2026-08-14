import Foundation

/// # Как зовётся модель конспекта: t=0, и один повтор на 0,3, если ответ схлопнулся
///
/// Всё в этом файле — перенос замеров со стенда `tools/recap-lab`
/// (OPTIMIZATION.md, A4 и «Методика», правило 1; эталон поведения —
/// `promptlib.call_ollama`). Промпты и семантика повторяются побайтово/пошагово —
/// «улучшение по пути» здесь означало бы немерянную конструкцию
/// (RELEASE-1.16.5.md, Г1).
///
/// Почему t=0: десять прогонов — один и тот же текст (σ = 0,0 против σ = 1,7 у
/// t=0,2), и это продуктовое обещание «кнопки „Сгенерировать заново" нет: повтор
/// вернул бы то же самое».
///
/// Почему повтор и почему не на t=0: у модели есть режим схлопывания — ответ в
/// 266–465 токенов вместо 707–1015 на побайтово том же промпте, и счёт по golden
/// почти функция длины (r = 0,78). При t=0 схлопывание детерминировано: на
/// `20260810_094722` все восемь прогонов вернули 684 токена — повтор на той же
/// температуре сгорает впустую. Поэтому повтор один, и идёт на 0,3.
///
/// Почему берётся длинный из двух, а не второй: вторая попытка тоже может
/// сорваться, и менять один огрызок на другой — потеря без выигрыша.
public enum RecapGenerationPolicy {

    /// Первый вызов — всегда детерминированный.
    public static let temperature = 0.0
    /// Температура **только повтора**: при t=0 повтор на t=0 вернёт тот же текст.
    public static let retryTemperature = 0.3

    /// Порог схлопывания для конспекта целиком и для свода из фактов.
    /// Здоровый конспект — 707–1015 токенов, схлопнувшийся — 266–465; порог 800
    /// разводит моды (стенд, «Методика», правило 1).
    public static let recapMinReplyTokens = 800
    /// Порог для извлечения фактов из фрагмента: ответ короче по построению.
    public static let extractMinReplyTokens = 600

    /// Версия конструкции генератора — в метаданные встречи и в телеметрию.
    ///
    /// nil в архиве = конспект собран до версий (1.16.4 и раньше, t=0,2 без
    /// ретрая); это «версия 1», и номер 1 намеренно не выдаётся ничему новому.
    /// 2 = lite: t=0 + один ретрай на 0,3 (+ механическая сборка переполняющих,
    /// когда доедет кусок 2). Старый код это поле не читает и обязан его молча
    /// пережить — проверяется даунгрейдом (RELEASE-1.16.5.md, Г6).
    public static let generatorVersion = 2

    /// Ответ модели, как его видит политика: текст и длина в токенах.
    /// `replyTokens == nil` — бэкенд длину не сообщил; такой ответ считается
    /// здоровым, потому что судить его не по чему.
    public struct ModelReply: Equatable, Sendable {
        public let content: String
        public let replyTokens: Int?

        public init(content: String, replyTokens: Int?) {
            self.content = content
            self.replyTokens = replyTokens
        }
    }

    /// Что произошло с одним вызовом — те же поля, что `stats` стенда, чтобы
    /// телеметрия прода и таблицы стенда читались одной головой.
    public struct CallStats: Equatable, Sendable {
        /// Длина первого ответа — чтобы схлопывание было видно в телеметрии,
        /// а не пряталось за удачным повтором.
        public let firstReplyTokens: Int?
        /// Длина ответа, который ушёл дальше по конвейеру.
        public let replyTokens: Int?
        /// Схлопнулся ли первый ответ.
        public let collapsedFirst: Bool
        /// Схлопнулся ли **итоговый**: после удачного повтора флаг снят, иначе
        /// телеметрия говорила бы «схлопнулось», когда починка уже сработала.
        public let collapsed: Bool
        public let retried: Bool
        public var calls: Int { retried ? 2 : 1 }

        public init(
            firstReplyTokens: Int?, replyTokens: Int?,
            collapsedFirst: Bool, collapsed: Bool, retried: Bool
        ) {
            self.firstReplyTokens = firstReplyTokens
            self.replyTokens = replyTokens
            self.collapsedFirst = collapsedFirst
            self.collapsed = collapsed
            self.retried = retried
        }
    }

    /// Схлопнулся ли ответ. Без порога вопроса нет.
    public static func collapsed(_ reply: ModelReply, threshold: Int?) -> Bool {
        guard let threshold, let tokens = reply.replyTokens else { return false }
        return tokens < threshold
    }

    /// Нужен ли повтор после первого ответа.
    public static func wantsRetry(first: ModelReply, threshold: Int?) -> Bool {
        collapsed(first, threshold: threshold)
    }

    /// Свести первый ответ и (если был) повтор к тому, что уходит дальше.
    ///
    /// Правило выбора — длинный из двух, при равенстве первый: детерминизм
    /// первого вызова дороже, чем ничья.
    public static func resolved(
        first: ModelReply, retry: ModelReply?, threshold: Int?
    ) -> (reply: ModelReply, stats: CallStats) {
        let collapsedFirst = collapsed(first, threshold: threshold)
        var winner = first
        if let retry, (retry.replyTokens ?? 0) > (first.replyTokens ?? 0) {
            winner = retry
        }
        let stats = CallStats(
            firstReplyTokens: first.replyTokens,
            replyTokens: winner.replyTokens,
            collapsedFirst: collapsedFirst,
            collapsed: collapsed(winner, threshold: threshold),
            retried: retry != nil
        )
        return (winner, stats)
    }

    /// Когорта памяти для телеметрии: «на каких машинах схлопывается» должно
    /// отвечаться фильтром по уже собранным данным. Грубые ступени, не байты —
    /// в сигналы не едет ничего точнее продуктового решения (8 ГБ уже страдают,
    /// RELEASE-1.16.5.md).
    public static func ramCohort(bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        if gib < 12 { return "8" }
        if gib < 24 { return "16" }
        return "32+"
    }
}
