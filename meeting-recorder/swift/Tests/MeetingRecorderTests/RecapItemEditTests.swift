import XCTest
@testable import PropellerPure

/// A checkbox on the project screen edits a file the person is not looking at.
/// Every case here is a byte the whole-document path would have lost on that
/// click — heading levels, indents, numbered lists, rules, unpaired `*`.
final class RecapItemEditTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MeetingRecorderTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/recap-item-edit/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines that differ between two versions of a document, as
    /// `(number, before, after)`. A surgical edit is supposed to produce a very
    /// short list.
    private func changedLines(_ before: String, _ after: String) -> [(Int, String, String)] {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        var out: [(Int, String, String)] = []
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : "<нет строки>"
            let right = i < b.count ? b[i] : "<нет строки>"
            if left != right { out.append((i, left, right)) }
        }
        return out
    }

    // MARK: - Тот же разбор, что у RecapDigest

    /// The whole point of the module is that a caller holding
    /// `RecapDigest.tasks[2]` can hand back `(section, 2, text)` and hit the
    /// right line. If the two parsers ever disagree, that promise is void.
    func testItemsMatchWhatTheDigestReports() throws {
        let text = try fixture("traps.md")
        let digest = RecapDigest.parse(text)
        let located = RecapItemEdit.locations(in: text)

        for title in ["Решения", "Задачи", "Открытые вопросы"] {
            let mine = located.filter { $0.section == title }.map(\.text)
            XCTAssertEqual(mine, digest.section(named: title)?.items ?? [], title)
        }
    }

    /// Everything before the first `##` is the document's name. The digest
    /// drops it, so it has no index — and an item nobody can name is an item
    /// nobody can edit by accident.
    func testNothingBeforeTheFirstHeadingIsAnItem() {
        let text = """
        # Синк — рекап
        - это не пункт секции, это шапка

        ## Решения
        - а это пункт
        """
        let located = RecapItemEdit.locations(in: text)
        XCTAssertEqual(located.map(\.text), ["а это пункт"])
        XCTAssertEqual(located.first?.index, 0)
    }

    // MARK: - Правка меняет одну строку

    func testCheckingATaskTouchesOneLineAndNothingElse() throws {
        let text = try fixture("traps.md")
        let target = RecapItemEdit.Target(
            section: "Задачи", index: 0,
            text: "[ ] **Левон** — написать Дену; до 19:00 завтра"
        )
        let edited = try XCTUnwrap(RecapItemEdit.replacing(
            target, in: text,
            with: "[x] **Левон** — написать Дену; до 19:00 завтра"
        ))

        let changed = changedLines(text, edited)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.1, "- [ ] **Левон** — написать Дену; до 19:00 завтра")
        XCTAssertEqual(changed.first?.2, "- [x] **Левон** — написать Дену; до 19:00 завтра")
    }

    func testDeletingATaskRemovesItsLineAndOnlyIt() throws {
        let text = try fixture("traps.md")
        let target = RecapItemEdit.Target(
            section: "Задачи", index: 1,
            text: "[x] **Ilyas Aitkulov** — обновить макеты"
        )
        let edited = try XCTUnwrap(RecapItemEdit.removing(target, from: text))

        XCTAssertEqual(edited.components(separatedBy: "\n").count,
                       text.components(separatedBy: "\n").count - 1)
        XCTAssertFalse(edited.contains("Ilyas Aitkulov"))
        // Соседи по списку на месте, и порядок не поехал.
        XCTAssertTrue(edited.contains("- [ ] **Левон** — написать Дену; до 19:00 завтра"))
        XCTAssertTrue(edited.contains("- [ ] обсудить flow демоскирования"))
    }

    /// A nested item keeps its indent and a `*` list keeps its marker: the
    /// document is somebody's file, and this module has no opinion about how
    /// they write lists.
    func testIndentAndMarkerSurviveTheEdit() throws {
        let text = try fixture("traps.md")
        let nested = RecapItemEdit.Target(
            section: "Решения", index: 2, text: "вложенный пункт со своим отступом"
        )
        let edited = try XCTUnwrap(RecapItemEdit.replacing(nested, in: text, with: "он же, но правленый"))
        XCTAssertTrue(edited.contains("   - он же, но правленый"))

        let starred = RecapItemEdit.Target(
            section: "Решения", index: 1, text: "Метрики выносим в отдельную встречу"
        )
        let after = try XCTUnwrap(RecapItemEdit.replacing(starred, in: text, with: "Метрики оставляем здесь"))
        XCTAssertTrue(after.contains("* Метрики оставляем здесь"))
    }

    /// An item the model wrapped by hand is one item to the reader, so it
    /// becomes one line — and the two lines it used to occupy both go.
    func testAWrappedItemCollapsesToOneLine() throws {
        let text = try fixture("traps.md")
        let target = RecapItemEdit.Target(
            section: "Решения", index: 3,
            text: "Пункт, который модель перенесла руками и продолжила на второй строке"
        )
        let edited = try XCTUnwrap(RecapItemEdit.replacing(target, in: text, with: "Пункт в одну строку"))
        XCTAssertEqual(edited.components(separatedBy: "\n").count,
                       text.components(separatedBy: "\n").count - 1)
        XCTAssertTrue(edited.contains("- Пункт в одну строку"))
        XCTAssertFalse(edited.contains("и продолжила на второй строке"))
    }

    // MARK: - Отказы

    /// The guard that makes the module safe to point at somebody else's file:
    /// the index alone is not enough, the text has to still be there.
    func testAnItemThatChangedUnderTheCallerIsNotEdited() throws {
        let text = try fixture("traps.md")
        let stale = RecapItemEdit.Target(
            section: "Задачи", index: 0, text: "[ ] **Левон** — написать кому-то другому"
        )
        XCTAssertNil(RecapItemEdit.locate(stale, in: text))
        XCTAssertNil(RecapItemEdit.replacing(stale, in: text, with: "[x] что угодно"))
        XCTAssertNil(RecapItemEdit.removing(stale, from: text))
    }

    func testAMissingSectionOrIndexIsRefused() throws {
        let text = try fixture("traps.md")
        XCTAssertNil(RecapItemEdit.locate(
            .init(section: "Заметки", index: 0, text: "чего тут нет"), in: text))
        XCTAssertNil(RecapItemEdit.locate(
            .init(section: "Задачи", index: 99, text: "чего тут нет"), in: text))
    }

    /// `RecapDigest` keeps gluing unmarked lines onto the last bullet across
    /// blank lines, so the last task of the fixture "owns" a numbered list and
    /// a horizontal rule below it. Reading it that way is harmless. Rewriting
    /// those lines as one would eat both — so the module refuses instead.
    func testAnItemStretchedAcrossABlankLineIsReadButNotEdited() throws {
        let text = try fixture("traps.md")
        let found = try XCTUnwrap(RecapItemEdit.locations(in: text)
            .first { $0.section == "Задачи" && $0.index == 2 })

        XCTAssertTrue(found.text.hasPrefix("[ ] обсудить flow демоскирования"))
        XCTAssertTrue(found.text.contains("1. Нумерованный пункт"))
        XCTAssertFalse(found.contiguous)

        let target = RecapItemEdit.Target(section: "Задачи", index: 2, text: found.text)
        XCTAssertNotNil(RecapItemEdit.locate(target, in: text))
        XCTAssertNil(RecapItemEdit.replacing(target, in: text, with: "[x] сделано"))
        XCTAssertNil(RecapItemEdit.removing(target, from: text))
    }

    func testAnEmptyOrMultilineBodyIsRefused() throws {
        let text = try fixture("traps.md")
        let target = RecapItemEdit.Target(
            section: "Решения", index: 0, text: "Каталог вакансий остаётся единым до конца года"
        )
        XCTAssertNil(RecapItemEdit.replacing(target, in: text, with: "   "))
        XCTAssertNil(RecapItemEdit.replacing(target, in: text, with: "две\nстроки"))
    }

    // MARK: - Добавление

    func testНовыйПунктВстаётПоследнимВСвоейСекции() throws {
        let text = try fixture("traps.md")
        let edited = try XCTUnwrap(
            RecapItemEdit.appending("написать Дене", toSection: "Задачи", in: text)
        )
        let items = RecapDigest.parse(edited).tasks
        XCTAssertEqual(items.last, "написать Дене")
        // Соседняя секция не сдвинулась и не выросла.
        XCTAssertEqual(RecapDigest.parse(edited).decisions,
                       RecapDigest.parse(text).decisions)
    }

    /// Маркер и отступ берутся у последнего пункта секции: документ, написанный
    /// звёздочками, остаётся со звёздочками.
    func testНовыйПунктНаследуетМаркерПоследнего() {
        let text = "## Решения\n* раз\n* два\n"
        XCTAssertEqual(
            RecapItemEdit.appending("три", toSection: "Решения", in: text),
            "## Решения\n* раз\n* два\n* три\n"
        )
    }

    func testВПустуюСекциюПунктВстаётПодЗаголовок() {
        let text = "## Задачи\n\n## Открытые вопросы\n- кто владелец\n"
        XCTAssertEqual(
            RecapItemEdit.appending("первая задача", toSection: "Задачи", in: text),
            "## Задачи\n- первая задача\n\n## Открытые вопросы\n- кто владелец\n"
        )
    }

    /// Секции нет — и заводить её этот модуль не берётся: где в документе место
    /// у `## Задачи` и есть ли оно вообще — вопрос про форму конспекта.
    func testБезСекцииДобавитьНекуда() {
        let text = "## Решения\n- раз\n"
        XCTAssertNil(RecapItemEdit.appending("что-то", toSection: "Задачи", in: text))
    }

    func testПустоеИМногострочноеТелоНеДобавляется() {
        let text = "## Задачи\n- раз\n"
        XCTAssertNil(RecapItemEdit.appending("   ", toSection: "Задачи", in: text))
        XCTAssertNil(RecapItemEdit.appending("две\nстроки", toSection: "Задачи", in: text))
    }

    /// Пункт добавляется в **первую** секцию с таким именем — туда же, куда
    /// смотрит `RecapDigest.section(named:)`.
    func testПриДвухОдноимённыхСекцияхПунктИдётВПервую() {
        let text = "## Задачи\n- раз\n\n## Итог\nПроза.\n\n## Задачи\n- вторая\n"
        XCTAssertEqual(
            RecapItemEdit.appending("два", toSection: "Задачи", in: text),
            "## Задачи\n- раз\n- два\n\n## Итог\nПроза.\n\n## Задачи\n- вторая\n"
        )
    }

    // MARK: - Зачем модуль существует

    /// The contrast the module was built for. Same file, same one-item change:
    /// the document path rewrites the file, the surgical path rewrites a line.
    /// If this ever stops failing on the left-hand side, the module is free to
    /// go away.
    func testTheWholeDocumentPathLosesWhatTheSurgicalPathKeeps() throws {
        let text = try fixture("traps.md")
        let rebuilt = SummaryDocument.parse(markdown: text).markdown
        XCTAssertNotEqual(rebuilt, text, "документный круг вдруг стал точным — проверить, нужен ли ещё RecapItemEdit")
        XCTAssertFalse(rebuilt.contains("### Что важно помнить"), "уровень заголовка")
        XCTAssertFalse(rebuilt.contains("   - вложенный"), "отступ вложенного пункта")
        XCTAssertTrue(rebuilt.contains("1. Нумерованный пункт 2. Второй нумерованный"), "нумерованный список схлопнулся в прозу")
        XCTAssertFalse(rebuilt.contains("***"), "горизонтальная линейка")
        XCTAssertTrue(rebuilt.contains("реорганизации*"), "одинокая звёздочка нашла себе пару")

        let target = RecapItemEdit.Target(
            section: "Задачи", index: 0,
            text: "[ ] **Левон** — написать Дену; до 19:00 завтра"
        )
        let surgical = try XCTUnwrap(RecapItemEdit.replacing(
            target, in: text, with: "[x] **Левон** — написать Дену; до 19:00 завтра"))
        XCTAssertTrue(surgical.contains("### Что важно помнить"))
        XCTAssertTrue(surgical.contains("   - вложенный пункт со своим отступом"))
        XCTAssertTrue(surgical.contains("1. Нумерованный пункт"))
        XCTAssertTrue(surgical.contains("***"))
        XCTAssertTrue(surgical.hasPrefix("---\ntitle: \"Синк по найму\""))
    }

    /// Two sections with one title: `RecapDigest.section(named:)` answers with
    /// the first, so the edit has to land in the first too.
    func testARepeatedSectionTitleResolvesToTheFirstOne() {
        let text = """
        ## Задачи
        - первая

        ## Итог
        Проза.

        ## Задачи
        - вторая
        """
        let edited = RecapItemEdit.replacing(
            .init(section: "Задачи", index: 0, text: "первая"), in: text, with: "правленая")
        XCTAssertEqual(edited, """
        ## Задачи
        - правленая

        ## Итог
        Проза.

        ## Задачи
        - вторая
        """)
    }

    /// Документ с виндовыми переводами строк читается и правится, а окончания
    /// строк у него остаются виндовыми — все до одной.
    ///
    /// Долго это был отказ: оба разбора режут файл по `\n` и снимали одни
    /// пробелы, поэтому возврат каретки оставался хвостом каждой строки,
    /// заголовок читался «Решения\r», и `section(named:)` не находил ничего —
    /// весь конспект выглядел пустым. Отказ был честным (пункта и правда не
    /// было), но причиной ему был дефект чтения, и починен он в чтении.
    func testДокументСВиндовымиПереводамиСтрокЧитаетсяИПравится() {
        let text = "## Решения\r\n- раз\r\n- два\r\n"
        XCTAssertEqual(RecapDigest.parse(text).section(named: "Решения")?.items, ["раз", "два"])

        let target = RecapItemEdit.Target(section: "Решения", index: 1, text: "два")
        XCTAssertEqual(RecapItemEdit.replacing(target, in: text, with: "три"),
                       "## Решения\r\n- раз\r\n- три\r\n")
        XCTAssertEqual(RecapItemEdit.removing(target, from: text),
                       "## Решения\r\n- раз\r\n")
        // Текст пункта отдаётся без возврата каретки, значит и ждут его таким:
        // строка с `\r` — это не тот пункт, который держит экран.
        XCTAssertNil(RecapItemEdit.replacing(
            .init(section: "Решения", index: 1, text: "два\r"), in: text, with: "три"
        ))
    }

    /// Дописанный пункт наследует окончание строки у соседа. Строка без
    /// возврата каретки в CRLF-документе — единственная во всём файле с другим
    /// окончанием, и следующий редактор покажет там мусор.
    func testДописанныйПунктНаследуетВиндовоеОкончаниеСтроки() {
        XCTAssertEqual(
            RecapItemEdit.appending("три", toSection: "Решения", in: "## Решения\r\n- раз\r\n"),
            "## Решения\r\n- раз\r\n- три\r\n"
        )
        // И у пустой секции — у её заголовка.
        XCTAssertEqual(
            RecapItemEdit.appending("раз", toSection: "Решения", in: "## Решения\r\n\r\n## Задачи\r\n- а\r\n"),
            "## Решения\r\n- раз\r\n\r\n## Задачи\r\n- а\r\n"
        )
    }

    /// The file ends without a trailing newline as often as with one, and
    /// nothing about an edit should add or drop it.
    func testTrailingNewlineIsNeitherAddedNorDropped() {
        let withNewline = "## Решения\n- раз\n- два\n"
        let target = RecapItemEdit.Target(section: "Решения", index: 1, text: "два")
        XCTAssertEqual(RecapItemEdit.replacing(target, in: withNewline, with: "три"),
                       "## Решения\n- раз\n- три\n")
        XCTAssertEqual(RecapItemEdit.removing(target, from: withNewline),
                       "## Решения\n- раз\n")

        let without = "## Решения\n- раз\n- два"
        XCTAssertEqual(RecapItemEdit.replacing(target, in: without, with: "три"),
                       "## Решения\n- раз\n- три")
    }
}
