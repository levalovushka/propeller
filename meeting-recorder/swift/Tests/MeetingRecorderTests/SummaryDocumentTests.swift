import XCTest
import PropellerPure

/// What the summary column shows, and what gets written back when it is edited.
///
/// The second half is the reason this type exists at all: the pane used to
/// *display* a recap, so a lossy parse was fine. Now it edits one, and every
/// case below that ends in a round trip is a file somebody would have lost.
final class SummaryDocumentTests: XCTestCase {

    private func kinds(_ document: SummaryDocument) -> [SummaryDocument.Block.Kind] {
        document.blocks.map(\.kind)
    }

    private func texts(_ document: SummaryDocument) -> [String] {
        document.blocks.map(\.text)
    }

    // MARK: - Reading a recap

    func testTheFirstParagraphBecomesTheLeadAndTheRestTheBody() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Договорились о редизайне.

        Спорили про рельс, сошлись на 300 pt.
        """)
        XCTAssertEqual(kinds(document), [.lead, .body])
        XCTAssertEqual(texts(document), ["Договорились о редизайне.", "Спорили про рельс, сошлись на 300 pt."])
        XCTAssertEqual(document.leadHeading, "## Итог")
    }

    func testALongSingleParagraphIsCutAtItsFirstSentence() {
        let long = "Решили переписать панель. "
            + String(repeating: "Дальше шло длинное обоснование этого решения. ", count: 6)
        let document = SummaryDocument.parse(markdown: "## Итог\n" + long)
        XCTAssertEqual(kinds(document), [.lead, .body])
        XCTAssertEqual(document.blocks[0].text, "Решили переписать панель.")
        XCTAssertTrue(document.blocks[1].text.hasPrefix("Дальше шло"))
    }

    func testAShortSummaryIsLeftWholeRatherThanSplit() {
        let document = SummaryDocument.parse(markdown: "## Итог\nКоротко. И ещё немного.")
        XCTAssertEqual(kinds(document), [.lead])
        XCTAssertEqual(document.blocks[0].text, "Коротко. И ещё немного.")
    }

    func testASentenceThatNeverEndsIsNotChoppedMidClause() {
        let unbroken = String(repeating: "слово ", count: 60).trimmingCharacters(in: .whitespaces)
        let document = SummaryDocument.parse(markdown: "## Итог\n" + unbroken)
        XCTAssertEqual(kinds(document), [.lead])
        XCTAssertEqual(document.blocks[0].text, unbroken)
    }

    func testHeadingsThatLostTheirHashesAreStillHeadings() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Всё решили.

        Решения
        - Рельс 300 pt
        - Заметки справа
        """)
        XCTAssertEqual(kinds(document), [.lead, .heading, .bullet, .bullet])
        XCTAssertEqual(document.blocks[1].text, "Решения")
    }

    func testASentenceIsNeverMistakenForAHeading() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Всё решили.

        Обсудили следующее:
        - Рельс
        """)
        XCTAssertEqual(kinds(document), [.lead, .body, .bullet])
        XCTAssertEqual(document.blocks[1].text, "Обсудили следующее:")
    }

    /// Two of the twenty-one recaps on the author's machine came back with plain
    /// lines instead of `##` all the way down, «Итог» included.
    func testARecapThatLostEveryHashIsStillReadable() {
        let document = SummaryDocument.parse(markdown: """
        Итог
        Обсудили релиз.

        Решения
        - Выкатываем в пятницу.
        - Фичефлаг оставляем на неделю.
        """)
        XCTAssertEqual(kinds(document), [.lead, .heading, .bullet, .bullet])
        XCTAssertEqual(document.blocks[0].text, "Обсудили релиз.")
        XCTAssertEqual(document.leadHeading, "Итог")
    }

    /// The rule that rescues the drifted recaps must not start eating prose.
    func testProseUnderAHeadingStaysProseRatherThanBecomingBullets() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Коротко.

        ## Ход обсуждения
        Начали с бюджета.
        Потом перешли к срокам.
        """)
        XCTAssertEqual(kinds(document), [.lead, .heading, .body])
        XCTAssertEqual(document.blocks[2].text, "Начали с бюджета. Потом перешли к срокам.")
    }

    // MARK: - Emphasis survives instead of being stripped

    func testABulletKeepsItsBoldLeadInAsBoldTextRatherThanLosingIt() {
        let document = SummaryDocument.parse(markdown: """
        ## Решения
        - **Мета как основа навигации:** темы под названием
        """)
        XCTAssertEqual(kinds(document), [.heading, .bullet])
        let spans = document.blocks[1].spans
        XCTAssertEqual(spans.first?.text, "Мета как основа навигации:")
        XCTAssertEqual(spans.first?.bold, true)
        XCTAssertEqual(spans.last?.bold, false)
        XCTAssertEqual(document.blocks[1].text, "Мета как основа навигации: темы под названием")
    }

    /// The read-only parse used to pull a colon *into* the bold lead-in, because
    /// a bold phrase ending mid-clause reads as a mistake. An editor may not:
    /// that is us rewriting the user's file on the way in, and it would come
    /// back out as `**Лёва:**` — a change nobody made, in a file they can see.
    func testAColonOutsideTheBoldStaysOutsideIt() {
        let document = SummaryDocument.parse(markdown: "## Задачи\n- **Лёва**: собрать сторибук.")
        let spans = document.blocks[1].spans
        XCTAssertEqual(spans.first?.text, "Лёва")
        XCTAssertEqual(spans.first?.bold, true)
        XCTAssertEqual(spans.last?.text, ": собрать сторибук.")
        XCTAssertTrue(document.markdown.contains("- **Лёва**: собрать сторибук."))
    }

    func testItalicAndBoldTogetherComeBackTheSameWay() {
        let document = SummaryDocument.parse(markdown: "## Итог\nЭто ***очень*** важно.")
        XCTAssertEqual(document.blocks[0].spans.count, 3)
        XCTAssertEqual(document.blocks[0].spans[1].text, "очень")
        XCTAssertTrue(document.blocks[0].spans[1].bold)
        XCTAssertTrue(document.blocks[0].spans[1].italic)
        XCTAssertEqual(document.markdown, "## Итог\n\nЭто ***очень*** важно.\n")
    }

    func testAnUnderscoreInsideAWordIsPartOfTheWord() {
        let document = SummaryDocument.parse(markdown: "## Итог\nФайл recap_service.swift переписан.")
        XCTAssertEqual(document.blocks[0].text, "Файл recap_service.swift переписан.")
    }

    // MARK: - Nothing to show

    func testNoRecapIsAnEmptyDocumentRatherThanACrash() {
        XCTAssertTrue(SummaryDocument.parse(markdown: "").isEmpty)
        XCTAssertTrue(SummaryDocument.parse(markdown: "\n\n   \n").isEmpty)
        XCTAssertEqual(SummaryDocument.parse(markdown: "").markdown, "")
    }

    func testAHeadingOverNothingIsNotDrawn() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Всё решили.

        ## Задачи

        ## Прочее
        Ничего.
        """)
        XCTAssertEqual(kinds(document), [.lead, .heading, .body])
        XCTAssertEqual(document.blocks[1].text, "Прочее")
    }

    // MARK: - Writing it back

    func testAnUneditedRecapComesBackAsTheSameDocument() {
        let markdown = """
        ## Итог
        Договорились о редизайне. Спорили про рельс.

        ## Решения
        - **Рельс:** 300 pt
        - Заметки справа

        ## Ход обсуждения
        Начали с того, что панель не читается.
        """
        let once = SummaryDocument.parse(markdown: markdown)
        let twice = SummaryDocument.parse(markdown: once.markdown)
        XCTAssertEqual(kinds(once), kinds(twice))
        XCTAssertEqual(texts(once), texts(twice))
        XCTAssertEqual(once.markdown, twice.markdown)
    }

    /// The one that would eat the summary a sentence at a time: a long «Итог»
    /// is split once, and the halves must not be split again on every save.
    func testASplitLeadIsNotSplitAgainOnTheNextSave() {
        let long = "Решили переписать панель. "
            + String(repeating: "Дальше шло длинное обоснование этого решения. ", count: 6)
        let once = SummaryDocument.parse(markdown: "## Итог\n" + long)
        let twice = SummaryDocument.parse(markdown: once.markdown)
        XCTAssertEqual(kinds(twice), [.lead, .body])
        XCTAssertEqual(once.blocks[0].text, twice.blocks[0].text)
        XCTAssertEqual(once.blocks[1].text, twice.blocks[1].text)
    }

    func testTheRecapsOwnHeadingIsPutBackWhereItWas() {
        let document = SummaryDocument.parse(markdown: "## Итог\nВсё решили.")
        XCTAssertTrue(document.markdown.hasPrefix("## Итог\n"))
    }

    func testARecapThatNeverHadAHeadingDoesNotGrowOne() {
        let document = SummaryDocument.parse(markdown: "Всё решили.\n\n## Задачи\n- Отправить смету")
        XCTAssertNil(document.leadHeading)
        XCTAssertEqual(document.markdown, "Всё решили.\n\n## Задачи\n\n- Отправить смету\n")
    }

    func testHeadingsThatLostTheirHashesGetThemBack() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Всё решили.

        Решения
        - Рельс 300 pt
        """)
        XCTAssertTrue(document.markdown.contains("## Решения"))
    }

    func testPlainTextDropsMarkupAndKeepsReadableStructure() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Решили переписать панель.

        Дальше шло обоснование с **важным** словом.

        ## Задачи
        - Отправить смету
        - Согласовать сроки
        """)
        XCTAssertEqual(
            document.plainText,
            """
            Решили переписать панель.

            Дальше шло обоснование с важным словом.

            Задачи

            • Отправить смету
            • Согласовать сроки
            """
        )
    }

    func testTwoBulletsStayOneListRatherThanBecomingTwoParagraphs() {
        let document = SummaryDocument.parse(markdown: "## Задачи\n- Первое\n- Второе")
        XCTAssertTrue(document.markdown.contains("- Первое\n- Второе"))
    }

    // MARK: - The YAML header an Obsidian vault reads

    /// In the «Obsidian» markdown format the recap file opens with `---` /
    /// `title:` / `tags:` / `---`. The parse knew nothing about it, so the two
    /// YAML lines glued into one paragraph and — being the lead section — were
    /// drawn at 20/26 semibold: the largest text in the window.
    func testTheVaultsYamlHeaderIsNotTheBiggestTextInTheColumn() {
        let document = SummaryDocument.parse(markdown: """
        ---
        title: "Разбор рельса — рекап"
        tags: [meeting, recap]
        ---

        ## Итог
        Договорились о редизайне.
        """)
        XCTAssertEqual(kinds(document), [.lead])
        XCTAssertEqual(texts(document), ["Договорились о редизайне."])
    }

    func testTheVaultsYamlHeaderComesBackByteForByte() {
        let file = """
        ---
        title: "Разбор рельса — рекап"
        tags: [meeting, recap]
        ---

        ## Итог

        Договорились о редизайне.

        ## Решения

        - Рельс 300 pt

        """
        XCTAssertEqual(SummaryDocument.parse(markdown: file).markdown, file)
    }

    /// The one that loses the file: an edit does not hand the parsed document
    /// back, it hands over a document the editor rebuilt from the text in the
    /// column, carrying `leadHeading` and nothing else. So the header has to
    /// ride in that field — a field of its own would be dropped here, which is
    /// exactly where `tags:` was disappearing from the vault.
    func testEditingASentenceLeavesTheVaultsYamlHeaderInTheFile() {
        let document = SummaryDocument.parse(markdown: """
        ---
        title: "Разбор рельса — рекап"
        tags: [meeting, recap]
        ---

        ## Итог
        Договорились о редизайне.
        """)
        // What `SummaryText.document(from:leadHeading:)` builds after a keystroke.
        let edited = SummaryDocument(
            blocks: [.init(id: "b0", kind: .lead, text: "Договорились о рельсе.")],
            leadHeading: document.leadHeading
        )
        XCTAssertEqual(edited.markdown, """
        ---
        title: "Разбор рельса — рекап"
        tags: [meeting, recap]
        ---

        ## Итог

        Договорились о рельсе.

        """)
    }

    /// A header over nothing is still not a summary — the column shows its
    /// placeholder — and the file keeps the header anyway.
    func testAFileThatIsNothingButAHeaderIsStillNoSummary() {
        let file = """
        ---
        title: "Разбор рельса — рекап"
        tags: [meeting, recap]
        ---

        """
        let document = SummaryDocument.parse(markdown: file)
        XCTAssertTrue(document.isEmpty)
        XCTAssertTrue(document.blocks.isEmpty)
        XCTAssertEqual(document.markdown, file)
    }

    /// With no closing `---` there is no header, only a rule — and a rule has
    /// always just ended a paragraph.
    func testARuleWithNothingClosingItIsNotMistakenForAHeader() {
        let document = SummaryDocument.parse(markdown: """
        ---
        Всё решили.
        """)
        XCTAssertNil(document.leadHeading)
        XCTAssertEqual(kinds(document), [.lead])
        XCTAssertEqual(document.markdown, "Всё решили.\n")
    }

    // MARK: - Editing

    func testChangingABlockKindChangesWhatIsWritten() {
        var document = SummaryDocument.parse(markdown: "## Итог\nВсё решили.\n\nПодробности тут.")
        document.blocks[1].kind = .heading
        XCTAssertTrue(document.markdown.contains("## Подробности тут."))
    }

    func testAnEmptyBlockIsNotWrittenOut() {
        var document = SummaryDocument.parse(markdown: "## Итог\nВсё решили.")
        document.blocks.append(.init(id: "new", kind: .body, text: "   "))
        XCTAssertEqual(document.markdown, "## Итог\n\nВсё решили.\n")
    }
}
