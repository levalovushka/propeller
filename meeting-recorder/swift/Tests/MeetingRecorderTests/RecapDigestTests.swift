import XCTest
import PropellerPure

/// Разбор конспекта проверяется формами, которые **есть на живом архиве**
/// (замер 2026-08-15, 106 файлов): заголовок с хвостовым пробелом, заголовок
/// болдом, пункт, перенесённый руками на вторую строку. Каждая из них однажды
/// означала бы «решений на этой встрече нет» там, где их пять.
final class RecapDigestTests: XCTestCase {

    private let recap = """
    # Запись 14.08.2026, 17:34 — рекап

    ## Итог
    Обсудили стратегию студии. Договорились о переходе к консалтингу
    и наборе команды до конца года.

    ## Решения
    - **Политика переработок:** овертайм только в исключительных случаях.
    - Стратегия ЦД: студия — консалтинговое агентство,
      а не разработчик приложений.

    ## Задачи
    - **Левон** — описать дизайн-язык версии 1.0.

    ## **Открытые вопросы**
    - Кто вычитывает результат агента — договорённости нет.

    ## Ход обсуждения
    - [12:30] Начали с найма.
    """

    func testSectionsSurviveTrailingSpacesAndBold() {
        let digest = RecapDigest.parse(recap)
        XCTAssertEqual(digest.decisions.count, 2)
        XCTAssertEqual(digest.openQuestions.count, 1)
        XCTAssertEqual(digest.tasks.count, 1)
    }

    func testAHandWrappedItemStaysOneItem() {
        let digest = RecapDigest.parse(recap)
        XCTAssertEqual(
            digest.decisions.last,
            "Стратегия ЦД: студия — консалтинговое агентство, а не разработчик приложений."
        )
    }

    func testTheSummaryIsProseAndKeepsItsWrappedLines() {
        let digest = RecapDigest.parse(recap)
        XCTAssertEqual(digest.summary.count, 1)
        XCTAssertTrue(digest.summary[0].hasSuffix("до конца года."))
    }

    /// Заголовок документа — не секция: иначе первая же строка файла уезжает в
    /// ответ как содержательный раздел.
    func testTheDocumentTitleIsNotASection() {
        let digest = RecapDigest.parse(recap)
        XCTAssertNil(digest.section(named: "Запись 14.08.2026, 17:34 — рекап"))
        XCTAssertEqual(digest.sections.count, 5)
    }

    /// «Нет секции» и «секция пуста» — разные ответы, и путать их нельзя:
    /// первое значит «модель об этом не писала», второе — «на встрече не было».
    func testAMissingSectionIsNotAnEmptyOne() {
        let digest = RecapDigest.parse("## Итог\nБыло тихо.")
        XCTAssertNil(digest.section(named: RecapDigest.decisionsTitle))
        XCTAssertEqual(digest.decisions, [])
    }

    func testEmptyDocumentGivesNoSections() {
        XCTAssertEqual(RecapDigest.parse("").sections.count, 0)
    }

    // MARK: - Таймкод

    func testTimecodeIsReadInBracketsAndAtTheStart() {
        XCTAssertEqual(RecapDigest.timecode(in: "[12:30] Начали с найма."), "12:30")
        XCTAssertEqual(RecapDigest.timecode(in: "14:20 — проверить итерации"), "14:20")
        XCTAssertEqual(RecapDigest.timecode(in: "[1:02:03] длинная встреча"), "1:02:03")
    }

    /// Самое дорогое место разбора: «синк в 15:00» — это договорённость о
    /// времени, а не место в записи. Выдать его как таймкод значит уверенно
    /// отправить читателя не туда.
    func testATimeInsideASentenceIsNotATimecode() {
        XCTAssertNil(RecapDigest.timecode(in: "Договорились, что синк будет в 15:00."))
        XCTAssertNil(RecapDigest.timecode(in: "Сдать к 20:34 в четверг."))
    }

    func testSecondsFromTimecode() {
        XCTAssertEqual(RecapDigest.seconds(fromTimecode: "12:30"), 750)
        XCTAssertEqual(RecapDigest.seconds(fromTimecode: "1:02:03"), 3723)
        XCTAssertNil(RecapDigest.seconds(fromTimecode: "полдень"))
        XCTAssertNil(RecapDigest.seconds(fromTimecode: ""))
    }
}
