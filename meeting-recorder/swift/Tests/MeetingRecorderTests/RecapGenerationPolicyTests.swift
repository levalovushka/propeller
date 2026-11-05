import XCTest
@testable import PropellerPure

/// Политика t=0 + один ретрай (`RecapGenerationPolicy`) — перенос семантики
/// `promptlib.call_ollama` со стенда. Каждый тест — правило, купленное замером;
/// сломать его — значит разойтись со стендом молча.
final class RecapGenerationPolicyTests: XCTestCase {

    private func reply(_ tokens: Int?, _ content: String = "x") -> RecapGenerationPolicy.ModelReply {
        .init(content: content, replyTokens: tokens)
    }

    // MARK: - Что считается схлопыванием

    func testAnswerOneTokenUnderThresholdIsCollapsed() {
        XCTAssertTrue(RecapGenerationPolicy.collapsed(reply(799), threshold: 800))
    }

    func testAnswerAtThresholdIsHealthy() {
        XCTAssertFalse(RecapGenerationPolicy.collapsed(reply(800), threshold: 800))
    }

    func testWithoutThresholdNothingCollapses() {
        XCTAssertFalse(RecapGenerationPolicy.collapsed(reply(1), threshold: nil))
    }

    /// Облако не сообщает eval_count — судить нечем, ретрай не жжётся впустую.
    func testUnknownLengthIsTreatedAsHealthy() {
        XCTAssertFalse(RecapGenerationPolicy.collapsed(reply(nil), threshold: 800))
        XCTAssertFalse(RecapGenerationPolicy.wantsRetry(first: reply(nil), threshold: 800))
    }

    // MARK: - Какой из двух ответов уходит дальше

    /// Вторая попытка тоже может сорваться — менять огрызок на огрызок нельзя.
    func testShorterRetryLosesToTheFirstAnswer() {
        let (winner, stats) = RecapGenerationPolicy.resolved(
            first: reply(700, "первый"), retry: reply(300, "повтор"), threshold: 800
        )
        XCTAssertEqual(winner.content, "первый")
        XCTAssertEqual(stats.replyTokens, 700)
        XCTAssertTrue(stats.retried)
    }

    func testLongerRetryWins() {
        let (winner, stats) = RecapGenerationPolicy.resolved(
            first: reply(300, "первый"), retry: reply(900, "повтор"), threshold: 800
        )
        XCTAssertEqual(winner.content, "повтор")
        XCTAssertEqual(stats.replyTokens, 900)
    }

    /// Ничья — первый: детерминизм первого вызова дороже.
    func testTieKeepsTheDeterministicFirstAnswer() {
        let (winner, _) = RecapGenerationPolicy.resolved(
            first: reply(500, "первый"), retry: reply(500, "повтор"), threshold: 800
        )
        XCTAssertEqual(winner.content, "первый")
    }

    // MARK: - Флаги, которые едут в телеметрию

    /// После удачного повтора `collapsed` снят, но `collapsedFirst` остаётся:
    /// таблица не должна говорить «схлопнулось», когда починка сработала, —
    /// и не должна прятать, что чинить пришлось.
    func testHealedRetryClearsCollapsedButKeepsCollapsedFirst() {
        let (_, stats) = RecapGenerationPolicy.resolved(
            first: reply(300), retry: reply(900), threshold: 800
        )
        XCTAssertTrue(stats.collapsedFirst)
        XCTAssertFalse(stats.collapsed)
        XCTAssertEqual(stats.calls, 2)
    }

    func testFailedRetryLeavesCollapsedSet() {
        let (_, stats) = RecapGenerationPolicy.resolved(
            first: reply(300), retry: reply(250), threshold: 800
        )
        XCTAssertTrue(stats.collapsedFirst)
        XCTAssertTrue(stats.collapsed)
    }

    func testHealthyAnswerMakesOneCallAndNoFlags() {
        let (_, stats) = RecapGenerationPolicy.resolved(
            first: reply(900), retry: nil, threshold: 800
        )
        XCTAssertFalse(stats.collapsedFirst)
        XCTAssertFalse(stats.collapsed)
        XCTAssertFalse(stats.retried)
        XCTAssertEqual(stats.calls, 1)
    }

    // MARK: - Разнос: 2026-10-29, `20261022_171723` генерировал 12 тысяч токенов

    private func runaway(_ tokens: Int?, _ content: String = "петля") -> RecapGenerationPolicy.ModelReply {
        .init(content: content, replyTokens: tokens, unfinished: true)
    }

    /// Потолок — ровно запас, который окно держит под ответ: длиннее окно не
    /// планировало, и на 997 ответах стенда длиннее 2154 не было ни одного.
    func testReplyCapIsTheWindowsReplyHeadroom() {
        XCTAssertEqual(RecapGenerationPolicy.maxReplyTokens, OllamaContext.replyTokens)
        XCTAssertGreaterThan(RecapGenerationPolicy.maxReplyTokens, 2154)
    }

    func testAnswerThatHitTheCapRanAway() {
        XCTAssertTrue(RecapGenerationPolicy.ranAway(runaway(3072)))
        XCTAssertTrue(RecapGenerationPolicy.ranAway(.timedOut))
        XCTAssertFalse(RecapGenerationPolicy.ranAway(reply(900)))
    }

    /// Тайм-аут раньше бросал исключение мимо повтора, и лестница слала тот же
    /// t=0 ещё раз. Теперь он просит повтора, как схлопывание, — и без порога:
    /// у редактуры и метаданных порога нет, а уйти в петлю они могут.
    func testRunawayAsksForRetryEvenWithoutThreshold() {
        XCTAssertTrue(RecapGenerationPolicy.wantsRetry(first: .timedOut, threshold: nil))
        XCTAssertTrue(RecapGenerationPolicy.wantsRetry(first: runaway(3072), threshold: 800))
        XCTAssertFalse(RecapGenerationPolicy.wantsRetry(first: reply(900), threshold: nil))
    }

    /// «Длинный из двух» отдал бы победу петле — она длиннее любого документа.
    func testCollapsedRetryBeatsRunawayFirst() {
        let (winner, stats) = RecapGenerationPolicy.resolved(
            first: runaway(3072), retry: reply(392, "огрызок"), threshold: 800
        )
        XCTAssertEqual(winner.content, "огрызок")
        XCTAssertTrue(stats.ranAwayFirst)
        XCTAssertFalse(stats.ranAway)
        XCTAssertTrue(stats.collapsed, "огрызок остаётся огрызком — флаг честный")
    }

    /// Тот же случай с другой стороны: первый ответ схлопнулся, повтор ушёл в
    /// разнос — дальше идёт первый, хоть он и короче.
    func testRunawayRetryNeverReplacesAFinishedFirst() {
        let (winner, stats) = RecapGenerationPolicy.resolved(
            first: reply(392, "огрызок"), retry: runaway(3072), threshold: 800
        )
        XCTAssertEqual(winner.content, "огрызок")
        XCTAssertFalse(stats.ranAway)
        XCTAssertFalse(stats.ranAwayFirst)
    }

    func testTwoRunawaysLeaveNothingToShip() {
        let (_, stats) = RecapGenerationPolicy.resolved(
            first: .timedOut, retry: runaway(3072), threshold: 800
        )
        XCTAssertTrue(stats.ranAway)
        XCTAssertTrue(stats.ranAwayFirst)
    }

    /// Петля, которая кончилась до потолка, — тоже разнос. Штраф за повтор у
    /// модели смотрит на 64 токена назад и длинную петлю не видит.
    func testRepeatedLineIsALoopEvenWhenTheReplyEnded() {
        let block = "- **Евгений Спиридонов** — согласен работать в формате парттайм\n"
        XCTAssertTrue(RecapGenerationPolicy.ranAway(reply(900, String(repeating: block, count: 3))))
        XCTAssertTrue(
            RecapGenerationPolicy.looped("\(block)  - **Евгений  Спиридонов** — согласен работать в формате парттайм\n\(block)"),
            "дрожащий отступ и двойной пробел петлю не прячут"
        )
    }

    /// Порог взят из архива: на 1611 документах строка от 16 символов
    /// повторялась не больше двух раз. Короткие строки повторяются законно.
    func testTwiceRepeatedLineAndShortLinesAreNotALoop() {
        let block = "- **Левон** — прислать смету по проекту\n"
        XCTAssertFalse(RecapGenerationPolicy.looped(block + block))
        XCTAssertFalse(RecapGenerationPolicy.looped(String(repeating: "- нет\n## Решения\n", count: 5)))
    }

    func testDoneReasonLengthReadsAsUnfinished() {
        XCTAssertTrue(BoundaryResponses.chatHitLength(
            data: Data(#"{"message":{"content":"ок"},"done_reason":"length"}"#.utf8)))
        XCTAssertFalse(BoundaryResponses.chatHitLength(
            data: Data(#"{"message":{"content":"ок"},"done_reason":"stop"}"#.utf8)))
        XCTAssertFalse(BoundaryResponses.chatHitLength(
            data: Data(#"{"message":{"content":"ок"}}"#.utf8)))
    }

    // MARK: - Когорта памяти

    func testRamCohortsMatchTheProductTiers() {
        XCTAssertEqual(RecapGenerationPolicy.ramCohort(bytes: 8 << 30), "8")
        XCTAssertEqual(RecapGenerationPolicy.ramCohort(bytes: 16 << 30), "16")
        XCTAssertEqual(RecapGenerationPolicy.ramCohort(bytes: 32 << 30), "32+")
        XCTAssertEqual(RecapGenerationPolicy.ramCohort(bytes: 64 << 30), "32+")
    }

    // MARK: - Чтение длины ответа из границы

    func testReplyTokensComeFromEvalCount() {
        let data = Data(#"{"message":{"content":"ок"},"eval_count":684}"#.utf8)
        XCTAssertEqual(BoundaryResponses.chatReplyTokens(data: data), 684)
    }

    func testMissingEvalCountReadsAsNil() {
        let data = Data(#"{"message":{"content":"ок"}}"#.utf8)
        XCTAssertNil(BoundaryResponses.chatReplyTokens(data: data))
    }

    /// Структурный признак дописанности («нет «Хода обсуждения» — повтор»)
    /// пробовали и сняли 2026-08-28: правило сработало на 9 первых ответах из
    /// 12, а секции после повтора не было у 6 из 12 против 4–5 без правила.
    /// Второй вызов на трёх четвертях встреч, ноль выигрыша — разбор в доке
    /// `RecapGenerationPolicy.resolved`. Тесты снятого правила удалены вместе с
    /// ним: тест на несуществующее поведение — это документация, которая врёт.
}
