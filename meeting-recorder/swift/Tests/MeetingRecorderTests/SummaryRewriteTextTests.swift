import XCTest
import PropellerPure

/// What «Подробнее» used to dump into the selection — and must not any more.
final class SummaryRewriteTextTests: XCTestCase {

    func testASingleSentencePassesThrough() {
        let spans = SummaryRewriteText.prepare("Договорились о редизайне.")
        XCTAssertEqual(spans.map(\.text), ["Договорились о редизайне."])
    }

    func testNewlinesCollapseSoOneSelectionStaysOneBlock() {
        let spans = SummaryRewriteText.prepare("""
            Сначала про рельс.

            Потом про заметки.
            """)
        XCTAssertEqual(SummaryRewriteText.plain("""
            Сначала про рельс.

            Потом про заметки.
            """), "Сначала про рельс. Потом про заметки.")
        XCTAssertEqual(spans.count, 1)
    }

    func testListMarkersAreStrippedRatherThanTypedIntoTheSummary() {
        let plain = SummaryRewriteText.plain("""
            - Рельс 300 pt
            - Заметки справа
            """)
        XCTAssertEqual(plain, "Рельс 300 pt Заметки справа")
        XCTAssertFalse(plain.contains("-"))
    }

    func testInlineBoldSurvivesAsASpanNotAsAsterisks() {
        let spans = SummaryRewriteText.prepare("**Рельс:** 300 pt, остальное без изменений")
        XCTAssertEqual(spans.first?.text, "Рельс:")
        XCTAssertEqual(spans.first?.bold, true)
        XCTAssertEqual(spans.dropFirst().first?.bold, false)
        XCTAssertFalse(SummaryRewriteText.plain("**Рельс:** 300").contains("*"))
    }

    func testAHeadingPrefixDoesNotBecomePartOfTheSentence() {
        XCTAssertEqual(
            SummaryRewriteText.plain("## Итог встречи про рельс"),
            "Итог встречи про рельс"
        )
    }

    func testEmptyOrMarkerOnlyAnswersProduceNothingToInsert() {
        XCTAssertTrue(SummaryRewriteText.prepare("").isEmpty)
        XCTAssertTrue(SummaryRewriteText.prepare("- ").isEmpty)
        XCTAssertTrue(SummaryRewriteText.prepare("\n\n").isEmpty)
    }
}
