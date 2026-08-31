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

    /// Резку длинного «Итога» по первому предложению сняли 2026-08-28: `.lead`
    /// рисуется ровно как `.body`, поэтому она делала из одного абзаца два
    /// визуально одинаковых — и спорила с решением «„Итог“ — ровно один абзац».
    /// Владелец увидел два абзаца на панели там, где в файле один.
    func testALongSingleParagraphStaysOneParagraph() {
        let long = "Решили переписать панель. "
            + String(repeating: "Дальше шло длинное обоснование этого решения. ", count: 6)
        let document = SummaryDocument.parse(markdown: "## Итог\n" + long)
        XCTAssertEqual(kinds(document), [.lead])
        XCTAssertEqual(document.blocks[0].text, long.trimmingCharacters(in: .whitespaces))
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
    ///
    /// С 2026-08-31 соседние строки не склеиваются: каждая — свой абзац. Тест
    /// остаётся про то, ради чего написан, — проза под заголовком не должна
    /// стать пунктами списка, — и только состав блоков теперь другой.
    func testProseUnderAHeadingStaysProseRatherThanBecomingBullets() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Коротко.

        ## Ход обсуждения
        Начали с бюджета.
        Потом перешли к срокам.
        """)
        XCTAssertEqual(kinds(document), [.lead, .heading, .body, .body])
        XCTAssertEqual(document.blocks[2].text, "Начали с бюджета.")
        XCTAssertEqual(document.blocks[3].text, "Потом перешли к срокам.")
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

    /// Заголовок над **подразделами** — не заголовок над пустотой.
    ///
    /// `## Ход обсуждения`, под которым сразу `### Обед с курьером`: своих
    /// строк у него нет, и разбор выбрасывал его вместе со строкой. Дальше
    /// сохранение писало результат поверх файла — строка пропадала навсегда.
    /// На живом архиве так съедены два последних конспекта (28 и 29 августа).
    func testAHeadingOverSubsectionsSurvivesEvenWithNoLinesOfItsOwn() {
        let document = SummaryDocument.parse(markdown: """
        ## Итог
        Всё решили.

        ## Ход обсуждения
        ### Обед с курьером
        Приехал вовремя.
        """)
        XCTAssertEqual(kinds(document), [.lead, .heading, .heading, .body])
        XCTAssertEqual(document.blocks[1].text, "Ход обсуждения")
        XCTAssertEqual(document.blocks[2].text, "Обед с курьером")
    }

    /// Тот же случай, но сравнение — с текстом, а не с самим собой: круг
    /// «разобрали → записали» проверяется против **исходной строки**, потому
    /// что именно её приложение перезаписывает на диске.
    ///
    /// Уровень решётки при этом теряется — `###` выходит как `##`; это
    /// зафиксировано отдельно (`RecapItemEditTests`) и здесь не чинится.
    /// Пропадать заголовок больше не имеет права.
    func testWritingBackASubheadingKeepsBothHeadingLines() {
        let markdown = "## Итог\nВсё решили.\n\n## Ход обсуждения\n### Обед с курьером\nПриехал вовремя.\n"
        XCTAssertEqual(
            SummaryDocument.parse(markdown: markdown).markdown,
            "## Итог\n\nВсё решили.\n\n## Ход обсуждения\n\n## Обед с курьером\n\nПриехал вовремя.\n"
        )
    }

    /// Конспект, уже написанный в нашей же форме, обязан вернуться байт в байт
    /// — не «так же, как во второй раз», а так же, как лежал.
    func testARecapAlreadyInOurOwnShapeComesBackByteForByte() {
        let markdown = "## Итог\n\nВсё решили.\n\n## Решения\n\n- Первое\n- Второе\n"
        XCTAssertEqual(SummaryDocument.parse(markdown: markdown).markdown, markdown)
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

    /// Тот, что съедал бы конспект по предложению за сохранение. Резки больше
    /// нет вовсе, поэтому круг обязан быть неподвижным с **первого** разбора, а
    /// не со второго.
    func testTheLeadSurvivesEveryRoundTripUnchanged() {
        let long = "Решили переписать панель. "
            + String(repeating: "Дальше шло длинное обоснование этого решения. ", count: 6)
        let once = SummaryDocument.parse(markdown: "## Итог\n" + long)
        let twice = SummaryDocument.parse(markdown: once.markdown)
        XCTAssertEqual(kinds(once), [.lead])
        XCTAssertEqual(kinds(twice), [.lead])
        XCTAssertEqual(once.blocks[0].text, twice.blocks[0].text)
        XCTAssertEqual(once.markdown, twice.markdown)
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
    // MARK: - Простой формат

    /// Файл, который приложение пишет по умолчанию, обязан пережить правку.
    ///
    /// Все прочие проверки круга начинаются с `## Итог` или с обсидиановых
    /// `---`, то есть с середины документа. А на диске у большинства людей
    /// лежит `RecapDocument.wrapped(format: .simple)` — и он начинается со
    /// строки `# Название — рекап`.
    // MARK: - Заметки

    /// Заметку начинает метка времени. Строки, разделённые одним переносом, —
    /// это две заметки (так их писали старые сборки), и склеивать их в абзац
    /// значит переписывать написанное человеком.
    func testTwoStampedNotesOnAdjacentLinesStayTwoNotes() {
        let markdown = """
        ## Итог
        Разбирали агентный дизайн.

        ## Заметки

        [14:20] проверить, сколько итераций уходит на один блок
        [51:05] вопрос Марине: кто вычитывает то, что агент нарисовал

        ## Решения
        - Отказались от общей дизайн-системы.
        """
        XCTAssertEqual(notes(of: markdown), [
            "[14:20] проверить, сколько итераций уходит на один блок",
            "[51:05] вопрос Марине: кто вычитывает то, что агент нарисовал",
        ])
    }

    /// А перенос **внутри** заметки её не делит.
    ///
    /// Строка без метки — продолжение предыдущей. Разрезав по каждому переносу,
    /// мы бы из одной заметки сделали три самостоятельных и без времени, и в
    /// файле это стало бы неотличимо от трёх настоящих. Проверено на архиве:
    /// так разъезжался `20260809_160755`.
    func testALineBreakInsideOneNoteDoesNotSplitIt() {
        let markdown = """
        ## Заметки

        [00:19] Начинаем писать,
        Теперь
        окно раширяется
        """
        XCTAssertEqual(notes(of: markdown), ["[00:19] Начинаем писать, Теперь окно раширяется"])
    }

    /// И переживает круг: правка конспекта не должна склеивать чужой текст.
    func testANoteSurvivesTheRoundTrip() {
        let markdown = """
        ## Итог
        Разбирали агентный дизайн.

        ## Заметки

        [14:20] первая
        [51:05] вторая
        """
        let once = SummaryDocument.parse(markdown: markdown).markdown
        XCTAssertTrue(once.contains("[14:20] первая"))
        XCTAssertTrue(once.contains("[51:05] вторая"))
        XCTAssertFalse(once.contains("[14:20] первая [51:05] вторая"))
        let twice = SummaryDocument.parse(markdown: once).markdown
        XCTAssertEqual(once, twice)
    }

    /// Вне «Заметок» перенос строки — тоже перенос, а не ширина строки.
    ///
    /// Тест перевёрнут 2026-08-31 вместе с правилом, и перевёрнут замером, а не
    /// вкусом: из 144 пар соседних строк прозы в живом архиве на перенос по
    /// ширине не похожа ни одна вне «Заметок». Зато 38 вторых строк начинались
    /// с таймкода и 14 — с `**Имя** — `, то есть склейка сливала отдельные темы
    /// и отдельные задачи в один абзац. Вход ниже — единственная форма, ради
    /// которой старое правило существовало (фраза, разорванная запятой), и
    /// теперь она даёт два абзаца: цена, заплаченная сознательно.
    func testOutsideTheNotesLinesAreEachTheirOwnParagraph() {
        let document = SummaryDocument.parse(markdown: """
        ## Решения
        Отказались от идеи барабана,
        потому что за пределами главного экрана он не обоснован.
        """)
        XCTAssertEqual(document.blocks.filter { $0.kind == .body }.count, 2)
    }

    /// То, ради чего правило переворачивали: тема с таймкодом и её описание —
    /// два разных абзаца, а не один. Так пишет модель весь «Ход обсуждения».
    func testATopicAndItsDescriptionDoNotBecomeOneWall() {
        let document = SummaryDocument.parse(markdown: """
        ## Ход обсуждения
        **[01:48] Концепция каталога:**
        Обсудили, зачем он нужен и кому.
        **[02:35] Бэклинки:**
        Введены ссылки назад к сущностям уровня выше.
        """)
        let bodies = document.blocks.filter { $0.kind == .body }.map(\.text)
        XCTAssertEqual(bodies.count, 4)
        XCTAssertEqual(bodies[0], "[01:48] Концепция каталога:")
        XCTAssertEqual(bodies[2], "[02:35] Бэклинки:")
    }

    /// И то же для задач: три исполнителя не становятся одним абзацем.
    func testTasksWrittenAsProseStayThreeTasksNotOneParagraph() {
        let document = SummaryDocument.parse(markdown: """
        ## Задачи
        **Левон** — подготовить доступы.
        **Радик** — описать прототипы.
        **Полина** — согласовать план встреч.
        """)
        XCTAssertEqual(document.blocks.filter { $0.kind == .body }.count, 3)
    }

    private func notes(of markdown: String) -> [String] {
        SummaryDocument.parse(markdown: markdown).blocks
            .drop(while: { $0.text != "Заметки" })
            .dropFirst()
            .prefix(while: { $0.kind == .body })
            .map(\.text)
    }

    func testПростойЗаголовокФайлаПереживаетПравку() {
        let file = RecapDocument.wrapped(
            title: "Синк по найму",
            recapBody: "## Итог\nОбсудили вилку.\n\n## Решения\n- Поднять оффер.",
            notes: nil,
            format: .simple
        )
        let document = SummaryDocument.parse(markdown: file)
        XCTAssertTrue(
            document.markdown.contains("# Синк по найму — рекап"),
            "заголовок документа пропал при первой же правке:\n\(document.markdown)"
        )
        // И второй проход ничего не двигает: файл, уже прошедший через правку,
        // должен собираться сам в себя, иначе он будет дрейфовать с каждой.
        let again = SummaryDocument.parse(markdown: document.markdown)
        XCTAssertEqual(again.markdown, document.markdown)
    }

    /// Обсидиановая шапка и заголовок документа не мешают друг другу.
    func testОбсидиановаяШапкаПереживаетПравкуКакИРаньше() {
        let file = RecapDocument.wrapped(
            title: "Синк по найму",
            recapBody: "## Итог\nОбсудили вилку.",
            notes: nil,
            format: .obsidian
        )
        let document = SummaryDocument.parse(markdown: file)
        XCTAssertTrue(document.markdown.hasPrefix("---\n"), document.markdown)
        XCTAssertTrue(document.markdown.contains("tags: [meeting, recap]"), document.markdown)
    }

}
