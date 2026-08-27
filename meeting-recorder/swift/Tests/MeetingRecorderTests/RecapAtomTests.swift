import XCTest
@testable import PropellerPure

/// Разбор пункта конспекта. Половина случаев здесь — про то, чего разбор
/// **не** должен додумать: угаданный ответственный хуже отсутствующего.
final class RecapAtomTests: XCTestCase {

    func testСогласованнаяРазметкаРазбираетсяЦеликом() {
        let atom = RecapAtom.parse("[ ] **Левон** — написать Дену; до 19:00 завтра")
        XCTAssertEqual(atom.checkbox, .todo)
        XCTAssertEqual(atom.assignee, "Левон")
        XCTAssertEqual(atom.body, "написать Дену; до 19:00 завтра")
        XCTAssertFalse(atom.isDone)
    }

    func testСделаннаяЗадачаЧитаетсяСделанной() {
        let atom = RecapAtom.parse("[x] **Ilyas Aitkulov** — обновить макеты")
        XCTAssertEqual(atom.checkbox, .done)
        XCTAssertTrue(atom.isDone)
        XCTAssertEqual(atom.assignee, "Ilyas Aitkulov")
        XCTAssertTrue(RecapAtom.parse("[X] сделано").isDone)
    }

    func testБезСкобокЗначитСкобокНетАНеЧтоНеСделано() {
        let atom = RecapAtom.parse("обсудить flow демоскирования")
        XCTAssertNil(atom.checkbox)
        XCTAssertFalse(atom.isDone)
        XCTAssertEqual(atom.body, "обсудить flow демоскирования")
    }

    /// Имя прозой ответственным не становится. Иначе однажды ответственным
    /// станет слово «Команда».
    func testИмяБезЖирногоНеОтветственный() {
        let atom = RecapAtom.parse("[ ] Левон — написать Дену")
        XCTAssertNil(atom.assignee)
        XCTAssertEqual(atom.body, "Левон — написать Дену")
    }

    /// Жирное без тире — тоже не ответственный: так модель выделяет термин
    /// внутри фразы.
    func testЖирноеБезТиреНеОтветственный() {
        let atom = RecapAtom.parse("[ ] **Каталог** остаётся единым до конца года")
        XCTAssertNil(atom.assignee)
        XCTAssertEqual(atom.body, "**Каталог** остаётся единым до конца года")
    }

    /// Дефис — не тире. По дефису рвались бы «Иванов-Петров» и «17-00».
    func testДефисНеСчитаетсяРазделителем() {
        XCTAssertNil(RecapAtom.parse("[ ] **Левон** - написать Дену").assignee)
    }

    func testСреднееТиреТожеРазделяет() {
        XCTAssertEqual(RecapAtom.parse("[ ] **Оля** – посчитать смету").assignee, "Оля")
    }

    func testПустоеЖирноеНеИмя() {
        XCTAssertNil(RecapAtom.parse("[ ] **** — что-то").assignee)
    }

    // MARK: - Круг

    func testРазобранноеСобираетсяОбратноБайтВБайт() {
        let lines = [
            "[ ] **Левон** — написать Дену; до 19:00 завтра",
            "[x] **Ilyas Aitkulov** — обновить макеты",
            "[ ] обсудить flow демоскирования",
            "Каталог остаётся единым до конца года",
            "[ ] **Каталог** остаётся единым до конца года",
            "Левон — написать Дену",
        ]
        for line in lines {
            XCTAssertEqual(RecapAtom.parse(line).item, line, line)
        }
    }

    func testГалочкаПереставляетсяИПоявляетсяТамГдеЕёНеБыло() {
        XCTAssertEqual(
            RecapAtom.parse("[ ] **Левон** — написать Дену").toggled().item,
            "[x] **Левон** — написать Дену"
        )
        XCTAssertEqual(
            RecapAtom.parse("[x] **Левон** — написать Дену").toggled().item,
            "[ ] **Левон** — написать Дену"
        )
        // У строки без скобок галочка появляется: вкладка «Задачи» показывает
        // квадрат каждой строке, а строки старых конспектов написаны прозой.
        XCTAssertEqual(
            RecapAtom.parse("обсудить flow").toggled().item,
            "[x] обсудить flow"
        )
    }

    func testСнятыйОтветственныйУходитВместеСТире() {
        XCTAssertEqual(
            RecapAtom.parse("[ ] **Левон** — написать Дену").withoutAssignee().item,
            "[ ] написать Дену"
        )
    }

    // MARK: - Проверки конспекта не гаснут от чекбокса

    /// Чекбокс встал между маркером и жирным именем — и обе проверки, которые
    /// читают строку задачи, обязаны это пережить. Погасшая проверка не падает
    /// и не жалуется: она просто перестаёт находить, и выдуманный исполнитель
    /// проезжает как отсутствующий.
    func testЧекбоксНеГаситПроверкуИсполнителей() {
        let recap = """
        ## Задачи
        - [ ] **Марина** — собрать референсы
        - [x] **Незнакомец** — сделать что-то
        - **Костя** — прогнать главную
        """
        let found = RecapLint.assigneesOutsideRoster(recap: recap, participants: ["Марина", "Костя"])
        XCTAssertEqual(found.map(\.text), ["Незнакомец"])
    }

    func testЧекбоксНеГаситПроверкуПризрачногоИсполнителя() {
        let recap = """
        ## Задачи
        - [ ] **Система** — присылать отчёт
        """
        XCTAssertTrue(
            RecapLint.findings(recap: recap, transcript: "", participants: [])
                .contains { $0.kind == .ghostOwner },
            "призрачный исполнитель перестал находиться из-за чекбокса"
        )
    }

    /// Правка задачи через хирургический модуль меняет одну строку файла и
    /// ничего больше — ради этого он и заведён.
    func testГалочкаЧерезХирургическийМодульМеняетОднуСтроку() {
        let text = """
        # Синк — рекап

        ## Задачи
        - [ ] **Левон** — написать Дену
        - [ ] обсудить flow

        ## Открытые вопросы
        - кто владелец
        """
        let items = RecapDigest.parse(text).tasks
        XCTAssertEqual(items.count, 2)

        let edited = RecapItemEdit.replacing(
            .init(section: RecapDigest.tasksTitle, index: 0, text: items[0]),
            in: text,
            with: RecapAtom.parse(items[0]).toggled().item
        )
        XCTAssertEqual(edited, """
        # Синк — рекап

        ## Задачи
        - [x] **Левон** — написать Дену
        - [ ] обсудить flow

        ## Открытые вопросы
        - кто владелец
        """)
    }
}
