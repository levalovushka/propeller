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
}
