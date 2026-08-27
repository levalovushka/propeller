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

    func testBoldInsideAHeadingIsTheHeadingsOwnEmphasis() {
        // Emphasis is its own attribute, not something read off the font. The
        // heading used to be bold itself, which made the case obvious; it is
        // 12/14 regular since 312:11129, and the reason still holds — a face
        // says how a block is drawn, never what the writer marked inside it.
        let document = SummaryDocument.parse(markdown: "## Решения\n- **Рельс:** 300 pt")
        let text = SummaryText.attributed(document, colour: ink)
        let back = SummaryText.document(from: text, leadHeading: nil)
        XCTAssertEqual(back.blocks[0].kind, .heading)
        XCTAssertEqual(back.blocks[0].spans.first?.bold, false)
        XCTAssertEqual(back.blocks[1].spans.first?.text, "Рельс:")
        XCTAssertEqual(back.blocks[1].spans.first?.bold, true)
    }

    /// Маркера на экране нет, а в файле пункт остаётся пунктом.
    ///
    /// Это и есть вся разница между `bullet` и `body` с 2026-08-27: она живёт
    /// в markdown, где её читают `RecapDigest` и MCP, и не живёт в пикселях.
    func testAnItemCarriesNoMarkerOnScreenAndStaysAnItemInTheFile() {
        let document = SummaryDocument.parse(markdown: "## Решения\n- Убрали барабан")
        let text = SummaryText.attributed(document, colour: ink)
        XCTAssertFalse(text.string.contains("•"))
        XCTAssertFalse(text.string.contains("\t"))
        XCTAssertTrue(text.string.contains("Убрали барабан"))

        let back = SummaryText.document(from: text, leadHeading: nil)
        XCTAssertEqual(back.blocks[1].kind, .bullet)
        XCTAssertEqual(back.blocks[1].text, "Убрали барабан")
        XCTAssertTrue(back.markdown.contains("- Убрали барабан"))
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
        // 312:11129: the lead stopped being a face of its own, and the section
        // heading stopped being bold — it became a label over the block.
        XCTAssertEqual(SummaryText.style(for: .lead).size, 13)
        XCTAssertEqual(SummaryText.style(for: .lead).weight, .regular)
        XCTAssertEqual(SummaryText.style(for: .heading).size, 12)
        XCTAssertEqual(SummaryText.style(for: .heading).weight, .regular)
        XCTAssertEqual(SummaryText.style(for: .body).size, 13)
        XCTAssertEqual(SummaryText.style(for: .bullet).size, 13)
    }

    /// A quiet heading is quiet because of its colour, and the colour is the
    /// only thing that says so — the face no longer differs from the body's.
    /// A screenshot could never turn red on this; this test can.
    func testTheSectionHeadingIsNotPaintedInTheColourOfTheBody() {
        let document = SummaryDocument(blocks: [
            .init(id: "h", kind: .heading, spans: [.init("Решения")]),
            .init(id: "b", kind: .body, spans: [.init("Отказались от барабана.")]),
        ], leadHeading: nil)
        let text = SummaryText.attributed(document, colour: ink)
        let heading = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let body = text.attribute(
            .foregroundColor, at: (text.string as NSString).range(of: "Отказались").location,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(body, ink)
        XCTAssertNotNil(heading)
        XCTAssertNotEqual(heading, body)
    }

    /// The gaps of 312:11129. Getting these wrong is invisible on one block and
    /// a different screen down a whole summary.
    func testTheGapsAreTheOnesTheCompsDrew() {
        XCTAssertEqual(SummaryText.spacingBefore(.lead, after: nil), 0)
        XCTAssertEqual(
            SummaryText.spacingBefore(.heading, after: .bullet), Tokens.Pane.summarySectionGap)
        XCTAssertEqual(
            SummaryText.spacingBefore(.bullet, after: .heading), Tokens.Pane.summaryHeadingGap)
        // A paragraph and a list item share one rhythm in the comps, so the
        // gap does not depend on which of the two stands where.
        XCTAssertEqual(
            SummaryText.spacingBefore(.bullet, after: .bullet), Tokens.Pane.summaryItemGap)
        XCTAssertEqual(
            SummaryText.spacingBefore(.body, after: .lead), Tokens.Pane.summaryItemGap)
        XCTAssertEqual(Tokens.Pane.summarySectionGap, 36)
        XCTAssertEqual(Tokens.Pane.summaryHeadingGap, 8)
        XCTAssertEqual(Tokens.Pane.summaryItemGap, 20)
    }
}
