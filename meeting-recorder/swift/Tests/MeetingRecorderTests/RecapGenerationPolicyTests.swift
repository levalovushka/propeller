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

    // MARK: - Дописанность, а не длина

    private func reply(_ text: String, tokens: Int?) -> RecapGenerationPolicy.ModelReply {
        .init(content: text, replyTokens: tokens)
    }

    private let whole = """
    ## Итог
    Собрались про смету.

    ## Решения
    - Отказались от диплинков.

    ## Ход обсуждения
    12:30 Спорили про хостинг.
    """

    private let cut = """
    ## Итог
    Собрались про смету.

    ## Решения
    - Отказались от диплинков.
    """

    /// Живой прогон встречи «Cетап Passwork»: 1782 символа — порога длины
    /// хватило, «Хода обсуждения» нет. Замер по 24 прогонам: секция есть у
    /// каждого ответа от 941 токена и ни у одного до 945, порог стоит на 800.
    func testОтветБезХодаОбсужденияПроситПовторДажеБудучиДлинным() {
        let long = reply(cut, tokens: 900)
        XCTAssertFalse(RecapGenerationPolicy.collapsed(long, threshold: 800))
        XCTAssertFalse(RecapGenerationPolicy.wantsRetry(first: long, threshold: 800))
        XCTAssertTrue(RecapGenerationPolicy.wantsRetry(
            first: long, threshold: 800, requiresDiscussion: true
        ))
    }

    func testДописанныйОтветПовтораНеПросит() {
        XCTAssertFalse(RecapGenerationPolicy.wantsRetry(
            first: reply(whole, tokens: 900), threshold: 800, requiresDiscussion: true
        ))
    }

    /// Дописанность важнее длины: короткий ответ с секцией побеждает длинный без.
    func testОтветСХодомПобеждаетБолееДлинныйБезНего() {
        let (winner, _) = RecapGenerationPolicy.resolved(
            first: reply(cut, tokens: 900),
            retry: reply(whole, tokens: 700),
            threshold: 800,
            requiresDiscussion: true
        )
        XCTAssertEqual(winner.content, whole)
    }

    /// А когда секцию не спрашивают, правило прежнее — длинный из двух.
    func testБезВопросаОСекцииПобеждаетДлинный() {
        let (winner, _) = RecapGenerationPolicy.resolved(
            first: reply(cut, tokens: 900), retry: reply(whole, tokens: 700), threshold: 800
        )
        XCTAssertEqual(winner.content, cut)
    }

    /// Оба без секции — выбор снова по длине, и повтор не сгорает впустую.
    func testЕслиНиОдинНеДописанБерётсяДлинный() {
        let (winner, stats) = RecapGenerationPolicy.resolved(
            first: reply(cut, tokens: 500), retry: reply(cut + "\n\nЕщё абзац.", tokens: 700),
            threshold: 800, requiresDiscussion: true
        )
        XCTAssertEqual(winner.replyTokens, 700)
        XCTAssertTrue(stats.retried)
        XCTAssertTrue(stats.collapsed)
    }

    /// Заголовок приезжает и болдом — разбор терпимый, значит и этот вопрос тоже.
    func testЖирныйЗаголовокСекцииСчитаетсяДописанным() {
        let bold = whole.replacingOccurrences(
            of: "## Ход обсуждения", with: "## **Ход обсуждения**"
        )
        XCTAssertFalse(RecapGenerationPolicy.missingDiscussion(reply(bold, tokens: 900)))
    }
}
