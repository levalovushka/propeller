import XCTest
import PropellerPure

/// Единственный сигнал, отвечающий на «пользуются ли фичей». Всё здесь про то,
/// чтобы он не соврал: ни в большую сторону (шум старта Клода), ни в меньшую
/// (потерянные вызовы), и чтобы в нём не оказалось ни слова из архива.
final class ClaudeUsageTests: XCTestCase {

    func testALineIsADayAndAToolAndNothingElse() {
        let line = ClaudeUsage.line(day: "2026-08-15", tool: "search_meetings")
        XCTAssertEqual(line, "2026-08-15\tsearch_meetings")
        XCTAssertFalse(line.contains(" "))
    }

    func testCallsAreCountedPerTool() {
        let log = """
        2026-08-15\tsearch_meetings
        2026-08-15\tget_recap
        2026-08-15\tsearch_meetings
        """
        let summary = ClaudeUsage.summarize(log)
        XCTAssertEqual(summary.calls, ["search_meetings": 2, "get_recap": 1])
        XCTAssertEqual(summary.total, 3)
    }

    /// Сколько дней человек возвращался — это и есть разница между «попробовал»
    /// и «пользуется».
    func testActiveDaysAreCounted() {
        let log = """
        2026-08-13\tsearch_meetings
        2026-08-15\tsearch_meetings
        2026-08-15\tget_recap
        """
        XCTAssertEqual(ClaudeUsage.summarize(log).activeDays, 2)
    }

    /// Журнал пишет другой процесс, и его могли убить на середине строки.
    /// Терять из-за этого весь замер незачем.
    func testATornLineIsSkippedAndTheRestSurvives() {
        let log = "2026-08-15\tsearch_meetings\nмусор\n\n2026-08-15\tget_rec"
        XCTAssertEqual(ClaudeUsage.summarize(log).calls, ["search_meetings": 1])
    }

    /// Имя инструмента уезжает параметром сигнала. Строка, дописанная в файл
    /// чем угодно, не должна становиться значением в аналитике.
    func testOnlyToolsWeDeclaredAreCounted() {
        let log = "2026-08-15\trm -rf\n2026-08-15\tget_transcript"
        XCTAssertEqual(ClaudeUsage.summarize(log).calls, ["get_transcript": 1])
    }

    func testAnEmptyLogSaysNothingRatherThanZero() {
        XCTAssertTrue(ClaudeUsage.summarize("").isEmpty)
        XCTAssertTrue(ClaudeUsage.summarize("\n\n").isEmpty)
    }

    func testEveryDeclaredToolCanBeCounted() {
        for tool in ClaudeMCP.tools {
            let summary = ClaudeUsage.summarize(ClaudeUsage.line(day: "2026-08-15", tool: tool.name))
            XCTAssertEqual(summary.calls[tool.name], 1, tool.name)
        }
    }

    func testFrequencyBuckets() {
        XCTAssertEqual(ClaudeUsage.frequencyBucket(0), "0")
        XCTAssertEqual(ClaudeUsage.frequencyBucket(1), "1")
        XCTAssertEqual(ClaudeUsage.frequencyBucket(5), "2-5")
        XCTAssertEqual(ClaudeUsage.frequencyBucket(20), "6-20")
        XCTAssertEqual(ClaudeUsage.frequencyBucket(21), "20+")
    }

    func testTheDayIsAPlainISODate() {
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let day = ClaudeUsage.day(date, timeZone: TimeZone(identifier: "Europe/Moscow")!)
        XCTAssertEqual(day.count, 10)
        XCTAssertEqual(day.filter { $0 == "-" }.count, 2)
    }
}
