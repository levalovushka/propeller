import XCTest
@testable import PropellerPure

/// Страховка авторского свода на пути нарезки (`RecapDigestGuard`).
///
/// Документ длинной встречи пишет модель — это решение владельца, и гвард не
/// про «какой текст лучше», а про «остался ли у свода текст вообще». Каждый
/// тест назван тем, что увидит читатель конспекта.
final class RecapDigestGuardTests: XCTestCase {

    /// Сборка `RecapAssembly` в миниатюре: восемь пунктов, как в замере A5.1
    /// (`13k-b`, механика дала 8 против 5 у свода).
    private let assembly = """
    ## Решения
    - Ильяс работает на базе знаний с 13 по 24 августа.
    - Камуфляжи с 17 августа уходят Владу Шукурову.
    - Задачи по стратегии закрывают к концу недели.
    - Полина не уходит в отпуск.

    ## Задачи
    - Левон — освободить время под задачи по стратегии.
    - Саша — проверить занятость Лёвы.
    - Илья и Лёв — база знаний до 18 числа.

    ## Открытые вопросы
    - Передача Ильяса на музыку не решена.

    ## Ход обсуждения
    Тактика | Лиды (00:05)
    """

    private func digest(bullets: Int) -> String {
        let items = (1...max(bullets, 1)).map { "- пункт \($0)" }.joined(separator: "\n")
        return "## Итог\nСобрались и договорились.\n\n## Решения\n\(items)"
    }

    // MARK: - Схлопнувшийся свод отдаёт документ сборке

    /// Живой ответ Ollama в режиме схлопывания: 351 токен при пороге 800.
    /// Через границу, а не строкой в тесте, — судить длину ответа умеет только
    /// `BoundaryResponses`, и именно она однажды читала не то поле.
    func testСхлопнувшийсяСводОтдаётДокументСборке() throws {
        let data = try Data(contentsOf: fixture("chat-collapsed-digest.json"))
        guard case .success(let content) = BoundaryResponses.readChatReply(data: data) else {
            return XCTFail("ответ границы не разобран")
        }
        let reply = RecapGenerationPolicy.ModelReply(
            content: content, replyTokens: BoundaryResponses.chatReplyTokens(data: data)
        )
        // Ретрай уже был и не помог: политика видит итог схлопнутым.
        let (winner, stats) = RecapGenerationPolicy.resolved(
            first: reply, retry: reply, threshold: RecapGenerationPolicy.recapMinReplyTokens
        )
        XCTAssertTrue(stats.collapsed)

        let decision = RecapDigestGuard.decide(
            digest: winner.content, collapsed: stats.collapsed, assembly: assembly
        )
        XCTAssertEqual(decision.author, .assembly)
        XCTAssertEqual(decision.recap, assembly)
        XCTAssertEqual(decision.reason, "свод схлопнут после ретрая")
    }

    /// Пустой ответ — тот же случай: отдавать читателю нечего.
    func testПустойСводОтдаётДокументСборке() {
        let decision = RecapDigestGuard.decide(digest: "  \n ", collapsed: false, assembly: assembly)
        XCTAssertEqual(decision.author, .assembly)
        XCTAssertEqual(decision.reason, "свод пуст")
    }

    // MARK: - Свод набрал длину, но потерял пункты

    /// Восемь пунктов пришло, три уехало — ровно то, чем свод и провинился в
    /// A5.1. Длина ответа при этом нормальная, ловит только сравнение с линейкой.
    func testСводСПотерейПунктовОтдаётДокументСборке() {
        let decision = RecapDigestGuard.decide(
            digest: digest(bullets: 3), collapsed: false, assembly: assembly
        )
        XCTAssertEqual(decision.author, .assembly)
        XCTAssertEqual(decision.recap, assembly)
        XCTAssertEqual(decision.reason, "в своде 3 пунктов против 8 в сборке")
    }

    /// Ровно половина — не потеря: порог отделяет съеденное содержание от
    /// редактуры, а не наказывает за каждый слитый пункт.
    func testПоловинаПунктовОстаётсяУАвтора() {
        let decision = RecapDigestGuard.decide(
            digest: digest(bullets: 4), collapsed: false, assembly: assembly
        )
        XCTAssertEqual(decision.author, .digest)
    }

    // MARK: - Здоровый свод остаётся документом

    /// Счастливый путь: у документа есть «Итог», и он написан одним автором.
    func testЗдоровыйСводОстаётсяДокументом() {
        let healthy = digest(bullets: 7)
        let decision = RecapDigestGuard.decide(
            digest: healthy, collapsed: false, assembly: assembly
        )
        XCTAssertEqual(decision.author, .digest)
        XCTAssertEqual(decision.recap, healthy)
        XCTAssertNil(decision.reason)
        XCTAssertTrue(decision.recap.contains("## Итог"))
    }

    /// Сборка тоже может не собраться — из фактов без меток не выходит ни
    /// одного пункта. Тогда отбирать документ нечем, и свод едет как есть.
    func testБезСборкиДокументОстаётсяУСвода() {
        let decision = RecapDigestGuard.decide(
            digest: digest(bullets: 1), collapsed: true, assembly: ""
        )
        XCTAssertEqual(decision.author, .digest)
        XCTAssertNil(decision.reason)
    }

    /// Сборка без буллетов (одна проза «Хода обсуждения») сравнивать себя не
    /// даёт: доля от нуля не значит ничего, и документ остаётся у автора.
    func testСборкаБезПунктовНеОтбираетДокумент() {
        let decision = RecapDigestGuard.decide(
            digest: digest(bullets: 1), collapsed: false,
            assembly: "## Ход обсуждения\nТактика | Лиды (00:05)"
        )
        XCTAssertEqual(decision.author, .digest)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MeetingRecorderTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/boundaries/\(name)")
    }
}
