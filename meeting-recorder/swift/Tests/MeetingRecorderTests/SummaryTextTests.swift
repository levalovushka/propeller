import XCTest
import AppKit
import PropellerPure
import PropellerUI

/// The other half of the round trip: the document becomes text you can put a
/// caret into, and has to come back out of it unchanged.
///
/// `SummaryDocumentTests` proves the file survives the parse. This proves it
/// survives the text view — which is where the bullet marker, the block kinds
/// and the emphasis actually live while somebody is typing.
final class SummaryTextTests: XCTestCase {

    private let ink = NSColor.white

    private func roundTrip(_ markdown: String) -> SummaryDocument {
        let document = SummaryDocument.parse(markdown: markdown)
        let text = SummaryText.attributed(document, colour: ink)
        return SummaryText.document(from: text, leadHeading: document.leadHeading)
    }

    private let sample = """
    ## Итог
    Договорились о редизайне.

    Спорили про рельс, сошлись на 300 pt.

    ## Решения
    - **Рельс:** 300 pt
    - Заметки справа

    ## Ход обсуждения
    Начали с того, что панель не читается.
    """

    func testAWholeRecapSurvivesBecomingEditableText() {
        let before = SummaryDocument.parse(markdown: sample)
        let after = roundTrip(sample)
        XCTAssertEqual(before.blocks.map(\.kind), after.blocks.map(\.kind))
        XCTAssertEqual(before.blocks.map(\.text), after.blocks.map(\.text))
        XCTAssertEqual(before.markdown, after.markdown)
    }

    func testBoldSurvivesEvenInsideAHeadingWhoseFaceIsAlreadyBold() {
        // Reading emphasis off the *font* cannot tell these apart, which is why
        // it is its own attribute.
        let document = SummaryDocument.parse(markdown: "## Решения\n- **Рельс:** 300 pt")
        let text = SummaryText.attributed(document, colour: ink)
        let back = SummaryText.document(from: text, leadHeading: nil)
        XCTAssertEqual(back.blocks[0].kind, .heading)
        XCTAssertEqual(back.blocks[0].spans.first?.bold, false)
        XCTAssertEqual(back.blocks[1].spans.first?.text, "Рельс:")
        XCTAssertEqual(back.blocks[1].spans.first?.bold, true)
    }

    func testTheBulletDiscIsNotPartOfTheBulletsText() {
        let document = SummaryDocument.parse(markdown: "## Задачи\n- Собрать смету")
        let text = SummaryText.attributed(document, colour: ink)
        XCTAssertTrue(text.string.contains(SummaryText.bulletMarker))
        let back = SummaryText.document(from: text, leadHeading: nil)
        XCTAssertEqual(back.blocks[1].text, "Собрать смету")
        XCTAssertFalse(back.markdown.contains("•"))
    }

    func testEveryParagraphKnowsWhichBlockItIsIncludingItsLineBreak() {
        let document = SummaryDocument.parse(markdown: sample)
        let text = SummaryText.attributed(document, colour: ink)
        // The caret sits *after* the last glyph of a line; if the newline
        // belonged to the next block, Return would open the wrong kind.
        for range in SummaryText.paragraphRanges(in: text.string) {
            let atStart = SummaryText.kind(in: text, at: range.location)
            let atEnd = SummaryText.kind(in: text, at: max(range.location, NSMaxRange(range) - 1))
            XCTAssertEqual(atStart, atEnd, "block kind changes inside one paragraph")
        }
    }

    func testAnEmptyRecapMakesEmptyTextRatherThanCrashing() {
        let text = SummaryText.attributed(.empty, colour: ink)
        XCTAssertEqual(text.length, 0)
        XCTAssertTrue(SummaryText.document(from: text, leadHeading: nil).isEmpty)
        XCTAssertTrue(SummaryText.paragraphRanges(in: "").isEmpty)
    }

    func testTextPastedWithNoAttributesReadsAsOrdinaryBodyRatherThanNothing() {
        let pasted = NSMutableAttributedString(string: "Просто вставленный абзац")
        let document = SummaryText.document(from: pasted, leadHeading: nil)
        XCTAssertEqual(document.blocks.map(\.kind), [.body])
        XCTAssertEqual(document.blocks[0].text, "Просто вставленный абзац")
    }

    // MARK: - Typography

    func testEachBlockGetsTheFaceTheComposDrewForIt() {
        XCTAssertEqual(SummaryText.style(for: .lead).size, 20)
        XCTAssertEqual(SummaryText.style(for: .heading).weight, .bold)
        XCTAssertEqual(SummaryText.style(for: .body).size, 14)
        XCTAssertEqual(SummaryText.style(for: .bullet).size, 14)
    }

    /// The gaps are the ones the `VStack` used to make. Getting these wrong is
    /// invisible on one block and a different screen down a whole summary.
    func testTheGapsAreTheOnesTheStackUsedToMake() {
        XCTAssertEqual(SummaryText.spacingBefore(.lead, after: nil), 0)
        XCTAssertEqual(SummaryText.spacingBefore(.body, after: .lead), Tokens.Pane.summaryLineGap)
        XCTAssertEqual(SummaryText.spacingBefore(.heading, after: .bullet), Tokens.Pane.summaryBlockGap)
        XCTAssertEqual(SummaryText.spacingBefore(.bullet, after: .heading), Tokens.Pane.summaryLineGap)
        XCTAssertEqual(SummaryText.spacingBefore(.bullet, after: .bullet), Tokens.Pane.bulletGap)
        XCTAssertEqual(Tokens.Pane.summaryLineGap, 15)
    }
}
