import XCTest
import PropellerPure

/// # Заметки в конспекте стоят там, где их читают
///
/// Названо тем, что человек видит: он открывает саммари и хочет найти в нём то,
/// что писал сам, — не дочитав до низа.
final class RecapNotesTests: XCTestCase {

    private let body = """
    ## Итог
    Собирались обсудить вики и договорились о мете.

    ## Решения
    - Мета описывается блоками.

    ## Задачи
    - Левон — собрать сторибук.
    """

    func testNotesStandUnderTheLeadAndAboveTheModelsFirstSection() {
        let out = RecapNotes.placed("Убедиться что все ошибки дают путь дальше", into: body)
        let headings = out.components(separatedBy: "\n").filter { $0.hasPrefix("##") }
        XCTAssertEqual(headings, ["## Итог", "## Заметки", "## Решения", "## Задачи"])
        XCTAssertTrue(out.contains("Убедиться что все ошибки дают путь дальше"))
    }

    /// Между заметкой и следующим заголовком остаётся пустая строка — иначе
    /// разбор склеит их в один абзац.
    func testTheBlockIsSeparatedFromWhatFollowsIt() {
        let out = RecapNotes.placed("одна заметка", into: body)
        let lines = out.components(separatedBy: "\n")
        let index = try! XCTUnwrap(lines.firstIndex(of: "одна заметка"))
        XCTAssertEqual(lines[index + 1], "")
        XCTAssertEqual(lines[index + 2], "## Решения")
    }

    /// Конспект в один раздел — вставлять некуда, но терять нельзя.
    func testWithNothingToStandAboveTheyGoLast() {
        let single = "## Итог\nКоротко обо всём."
        let out = RecapNotes.placed("хвостом", into: single)
        XCTAssertTrue(out.hasSuffix("## Заметки\n\nхвостом"))
    }

    func testAnUnheadedRecapKeepsThemToo() {
        let out = RecapNotes.placed("хвостом", into: "Просто проза без единого заголовка.")
        XCTAssertTrue(out.contains("## Заметки"))
        XCTAssertTrue(out.hasSuffix("хвостом"))
    }

    /// Пустой раздел ничем не отличается от раздела, который забыли заполнить.
    func testNoNotesMeansNoSection() {
        XCTAssertEqual(RecapNotes.placed(nil, into: body), body)
        XCTAssertEqual(RecapNotes.placed("   \n  ", into: body), body)
    }

    // MARK: - Раздел принадлежит человеку

    /// Модель попросили вплетать заметки по смыслу, а не выносить списком. Если
    /// она всё-таки выдала свой «Заметки» — в файле окажется один раздел, наш, а
    /// не два одинаковых заголовка подряд.
    func testTheModelsOwnNotesSectionIsReplacedRatherThanJoined() {
        let disobedient = """
        ## Итог
        Итог.

        ## Заметки
        Пересказ моделью того, что я писал.

        ## Решения
        - Решение.
        """
        let out = RecapNotes.placed("мой текст", into: disobedient)
        let headings = out.components(separatedBy: "\n").filter { $0.hasPrefix("##") }
        XCTAssertEqual(headings, ["## Итог", "## Заметки", "## Решения"])
        XCTAssertTrue(out.contains("мой текст"))
        XCTAssertFalse(out.contains("Пересказ моделью"))
    }

    /// Файл, собранный прежней сборкой, несёт этот раздел в конце. Пересборка
    /// не должна дописать второй.
    func testAFileFromTheOldLayoutIsRebuiltRatherThanAppendedTo() {
        let old = body + "\n\n## Заметки\n\nстарая заметка\n"
        let out = RecapNotes.placed("новая заметка", into: old)
        let headings = out.components(separatedBy: "\n").filter { $0.hasPrefix("##") }
        XCTAssertEqual(headings, ["## Итог", "## Заметки", "## Решения", "## Задачи"])
        XCTAssertFalse(out.contains("старая заметка"))
    }

    func testStrippingLeavesTheRestOfTheRecapAlone() {
        let withNotes = RecapNotes.placed("что-то", into: body)
        XCTAssertEqual(RecapNotes.stripped(withNotes), body)
    }
}
