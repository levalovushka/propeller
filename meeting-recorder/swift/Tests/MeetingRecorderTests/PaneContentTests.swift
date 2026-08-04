import XCTest
import PropellerPure

/// The two pure pieces the pane is built on: what a recap becomes, and how a
/// decade of single-blob notes becomes a list without losing anything.
final class PaneContentTests: XCTestCase {

    // MARK: - Recap → summary

    func testTheFirstParagraphBecomesTheLeadAndTheRestTheBody() {
        let summary = RecapPresentation.summary(fromMarkdown: """
        ## Итог
        Провели воркшоп по музыкальному приложению.

        Ключевая цель — снизить когнитивную нагрузку.
        """)
        XCTAssertEqual(summary.lead, "Провели воркшоп по музыкальному приложению.")
        XCTAssertEqual(summary.body, "Ключевая цель — снизить когнитивную нагрузку.")
    }

    func testALongSingleParagraphIsCutAtItsFirstSentence() {
        // Every one of the twenty-one recaps on the author's machine came back
        // with «Итог» as a *single* paragraph of 109–586 characters, where the
        // comps expect a sentence at 18 pt and a paragraph at 14. Setting 586
        // characters in 18 pt semibold is a wall.
        let long = String(repeating: "Слово ", count: 30) + "конец. " + String(repeating: "Ещё ", count: 30)
        let summary = RecapPresentation.summary(fromMarkdown: "## Итог\n" + long)
        XCTAssertTrue(summary.lead.hasSuffix("конец."), "got: \(summary.lead.suffix(20))")
        XCTAssertFalse(summary.body.isEmpty)
    }

    func testAShortSummaryIsLeftWholeRatherThanSplit() {
        let summary = RecapPresentation.summary(fromMarkdown: "## Итог\nКоротко. И ещё немного.")
        XCTAssertEqual(summary.lead, "Коротко. И ещё немного.")
        XCTAssertTrue(summary.body.isEmpty)
    }

    func testASentenceThatNeverEndsIsNotChoppedMidClause() {
        // A lead that stops in the middle of a thought is worse than a long one.
        let unbroken = String(repeating: "слово ", count: 60)
        let summary = RecapPresentation.summary(fromMarkdown: "## Итог\n" + unbroken)
        XCTAssertEqual(summary.lead, unbroken.trimmingCharacters(in: .whitespaces))
        XCTAssertTrue(summary.body.isEmpty)
    }

    func testHeadingsThatLostTheirHashesAreStillHeadings() {
        // Two of the twenty-one recaps on the author's machine came back with
        // plain lines instead of `##` for the first few headings. A parser that
        // trusts the hashes renders those as one wall of text.
        let summary = RecapPresentation.summary(fromMarkdown: """
        Итог
        Обсудили релиз.

        Решения
        - Выкатываем в пятницу.
        - Фичефлаг оставляем на неделю.
        """)
        XCTAssertEqual(summary.lead, "Обсудили релиз.")
        XCTAssertEqual(summary.sections.count, 1)
        XCTAssertEqual(summary.sections.first?.title, "Решения")
        XCTAssertEqual(summary.sections.first?.blocks.count, 2)
    }

    func testASentenceIsNeverMistakenForAHeading() {
        // The rule that rescues the drifted recaps must not start eating prose.
        let summary = RecapPresentation.summary(fromMarkdown: """
        ## Итог
        Коротко.

        ## Ход обсуждения
        Начали с бюджета.
        Потом перешли к срокам.
        """)
        XCTAssertEqual(summary.sections.count, 1)
        XCTAssertEqual(summary.sections.first?.title, "Ход обсуждения")
        // Prose stays prose — a disc in front of every paragraph is not a list.
        if case .paragraph = summary.sections.first?.blocks.first {} else {
            XCTFail("prose in «Ход обсуждения» should not become a bullet")
        }
    }

    func testABulletKeepsItsBoldLeadInAndTheColonWithIt() {
        let summary = RecapPresentation.summary(fromMarkdown: """
        ## Решения
        - **Мета как основа навигации:** Метаданные описываются блоками.
        """)
        guard case .bullet(_, let lead, let text) = summary.sections.first?.blocks.first else {
            return XCTFail("expected a bullet")
        }
        XCTAssertEqual(lead, "Мета как основа навигации: ")
        XCTAssertEqual(text, "Метаданные описываются блоками.")
    }

    func testAColonOutsideTheEmphasisMovesInside() {
        // The model writes it both ways; a bold phrase ending mid-clause reads
        // as a mistake, so the colon always joins the lead.
        let summary = RecapPresentation.summary(fromMarkdown: """
        ## Задачи
        - **Лёва**: собрать сторибук.
        """)
        guard case .bullet(_, let lead, let text) = summary.sections.first?.blocks.first else {
            return XCTFail("expected a bullet")
        }
        XCTAssertEqual(lead, "Лёва: ")
        XCTAssertEqual(text, "собрать сторибук.")
    }

    func testABulletWithoutEmphasisHasNoLead() {
        let summary = RecapPresentation.summary(fromMarkdown: """
        ## Решения
        - Просто пункт.
        """)
        guard case .bullet(_, let lead, let text) = summary.sections.first?.blocks.first else {
            return XCTFail("expected a bullet")
        }
        XCTAssertNil(lead)
        XCTAssertEqual(text, "Просто пункт.")
    }

    func testEmptySectionsAreDropped() {
        // The prompt says to omit empty sections; when the model leaves one
        // behind anyway, a bare heading with nothing under it is worse than
        // nothing at all.
        let summary = RecapPresentation.summary(fromMarkdown: """
        ## Итог
        Коротко.

        ## Открытые вопросы

        ## Решения
        - Есть.
        """)
        XCTAssertEqual(summary.sections.map(\.title), ["Решения"])
    }

    func testNoRecapIsAnEmptySummaryRatherThanACrash() {
        XCTAssertTrue(RecapPresentation.summary(fromMarkdown: "").isEmpty)
        XCTAssertTrue(RecapPresentation.summary(fromMarkdown: "\n\n   \n").isEmpty)
    }

    func testStraySeparatorsDoNotLeakIntoTheText() {
        let summary = RecapPresentation.summary(fromMarkdown: "## Итог\nЕсть **важное** слово.")
        XCTAssertEqual(summary.lead, "Есть важное слово.")
    }

    // MARK: - Notes

    func testALegacyBlobBecomesOneNotePerParagraph() {
        let notes = MeetingNotes.migrate(from: "Первая\n\nВторая строка\nи её продолжение")
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].text, "Первая")
        XCTAssertEqual(notes[1].text, "Вторая строка\nи её продолжение")
    }

    func testASingleNewlineDoesNotSplitANote() {
        // A bulleted note is one note. Splitting every newline turns it into five.
        let notes = MeetingNotes.migrate(from: "план:\n* раз\n* два")
        XCTAssertEqual(notes.count, 1)
    }

    func testMigrationIsStableSoAReReadCannotDuplicate() {
        let blob = "Раз\n\nДва"
        XCTAssertEqual(
            MeetingNotes.migrate(from: blob).map(\.id),
            MeetingNotes.migrate(from: blob).map(\.id)
        )
    }

    func testTheBlobEveryOlderReaderSeesSurvivesARoundTrip() {
        // The overlay, the markdown writer, the recap prompt and search all read
        // `notes`. Records are the new truth; the blob has to stay their exact
        // rendering or an old build opens the archive and sees notes vanish.
        let blob = "Первая\n\nВторая"
        let records = MeetingNotes.migrate(from: blob)
        XCTAssertEqual(MeetingNotes.blob(from: records), blob)
    }

    func testEmptyNotesAreNoNotes() {
        XCTAssertTrue(MeetingNotes.migrate(from: nil).isEmpty)
        XCTAssertTrue(MeetingNotes.migrate(from: "   \n\n  ").isEmpty)
    }

    func testStoredRecordsWinOverTheBlob() {
        let records = [MeetingNoteRecord(id: "a", text: "Новая")]
        XCTAssertEqual(
            MeetingNotes.resolved(items: records, blob: "старое").map(\.text),
            ["Новая"]
        )
        XCTAssertEqual(
            MeetingNotes.resolved(items: nil, blob: "старое").map(\.text),
            ["старое"]
        )
    }
}

