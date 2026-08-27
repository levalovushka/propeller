import XCTest
@testable import PropellerPure

/// Предложить проект — половина работы; вторая половина в том, чтобы
/// промолчать. Больше половины случаев здесь про молчание.
final class ProjectCandidateTests: XCTestCase {

    private func meeting(
        _ id: String, _ title: String, event: String? = nil, series: String? = nil,
        projects: [String] = [], day: Int = 1
    ) -> ProjectCandidate.Meeting {
        ProjectCandidate.Meeting(
            id: id, title: title, eventTitle: event, seriesID: series, projects: projects,
            date: Date(timeIntervalSince1970: 1_780_000_000 + Double(day) * 86_400)
        )
    }

    // MARK: - Когда предлагаем

    func testДвеВстречиОднойСерииРождаютПредложение() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "PG x VK Музыка", series: "S-1", day: 1),
            meeting("2", "PG x VK Музыка", series: "S-1", day: 8),
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.name, "PG x VK Музыка")
        // Ретро-привязка — не отдельный шаг, а тот же список, которым
        // предложение обосновано. От новых к старым.
        XCTAssertEqual(found.first?.meetings, ["2", "1"])
    }

    func testОднаВстречаНеПовторение() {
        XCTAssertTrue(ProjectCandidate.suggestions(for: [
            meeting("1", "PG x VK Музыка", series: "S-1")
        ]).isEmpty)
    }

    func testБезСерииСкладываютсяПоНазванию() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "Менторство с Лёшей", day: 1),
            meeting("2", "менторство с лёшей", day: 8),
        ])
        XCTAssertEqual(found.count, 1)
        // Имя берётся у первой встречи связки, а не приводится к нижнему
        // регистру: свёртка нужна для сравнения, а не для показа.
        XCTAssertEqual(found.first?.name, "Менторство с Лёшей")
    }

    /// Серия сильнее названия: два «Дейлика» разных команд — два дейлика, и
    /// слепить их по совпадению слова значило бы смешать чужие проекты.
    func testОдноНазваниеРазныеСерииНеОдинПроект() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "Дейлик", event: "Дейлик ВК", series: "S-1", day: 1),
            meeting("2", "Дейлик", event: "Дейлик ВК", series: "S-1", day: 2),
            meeting("3", "Дейлик", event: "Дейлик ГПН", series: "S-2", day: 1),
            meeting("4", "Дейлик", event: "Дейлик ГПН", series: "S-2", day: 2),
        ])
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.name)), ["Дейлик ВК", "Дейлик ГПН"])
    }

    func testНазваниеСобытияСильнееНазванияВстречи() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "Разговор про найм", event: "Найм дизайнера", series: "S", day: 1),
            meeting("2", "Ещё раз про найм", event: "Найм дизайнера", series: "S", day: 8),
        ])
        XCTAssertEqual(found.first?.name, "Найм дизайнера")
    }

    // MARK: - Когда молчим

    /// Безымянный проект хуже отсутствующего (§3, правило 5).
    func testМусорноеНазваниеНеРождаетПредложения() {
        for junk in ["Встреча", "созвон", "Новая встреча", "Zoom Meeting",
                     "untitled", "Запись 26.08.2026, 18:20", "  ", "..."] {
            let found = ProjectCandidate.suggestions(for: [
                meeting("1", junk, series: "S", day: 1),
                meeting("2", junk, series: "S", day: 8),
            ])
            XCTAssertTrue(found.isEmpty, junk)
        }
    }

    /// «Записи подкаста» — законное имя проекта. Отбрасывается только то, что
    /// приложение назвало само: слово плюс дата.
    func testАвтоназваниеОтбрасываетсяАОднокоренноеИмяНет() {
        XCTAssertTrue(ProjectCandidate.isJunk("Запись 26.08.2026, 18:20"))
        XCTAssertFalse(ProjectCandidate.isJunk("Записи подкаста"))
        XCTAssertFalse(ProjectCandidate.isJunk("Запись альбома"))
    }

    /// «ЦД» — законное имя проекта из двух букв. Стоп-список, а не длина.
    func testКороткоеНоОсмысленноеНазваниеПроходит() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "ЦД", series: "S", day: 1),
            meeting("2", "ЦД", series: "S", day: 8),
        ])
        XCTAssertEqual(found.first?.name, "ЦД")
    }

    /// Мусорное название события не отменяет осмысленного названия встречи:
    /// модель переписывает «Созвон» в то, о чём говорили.
    func testМусорноеСобытиеУступаетОсмысленнойВстрече() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "Найм дизайнера", event: "Созвон", series: "S", day: 1),
            meeting("2", "Найм дизайнера", event: "Созвон", series: "S", day: 8),
        ])
        XCTAssertEqual(found.first?.name, "Найм дизайнера")
    }

    /// У встречи уже есть проект — её не предлагают ни как повод, ни как добычу.
    func testПомеченныеВстречиВПредложенияНеПопадают() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "PG x VK", series: "S", projects: ["p1"], day: 1),
            meeting("2", "PG x VK", series: "S", projects: ["p1"], day: 8),
            meeting("3", "PG x VK", series: "S", day: 15),
        ])
        XCTAssertTrue(found.isEmpty, "одна непомеченная встреча повторением не является")
    }

    /// Крестик — навсегда (§3, правило 3). Второй раз то же не спрашивают.
    func testЗаглушённаяСвязкаНеПредлагаетсяСнова() {
        let rows = [
            meeting("1", "PG x VK", series: "S-1", day: 1),
            meeting("2", "PG x VK", series: "S-1", day: 8),
        ]
        let key = ProjectCandidate.suggestions(for: rows).first!.key
        XCTAssertTrue(ProjectCandidate.suggestions(silenced: [key], for: rows).isEmpty)
    }

    /// Ключ устойчив между запусками: это серия или свёрнутое имя, а не место в
    /// списке. Иначе «навсегда» жило бы до перезапуска.
    func testКлючСвязкиНеЗависитОтПорядкаИРегистра() {
        let a = ProjectCandidate.suggestions(for: [
            meeting("1", "Менторство", day: 1), meeting("2", "МЕНТОРСТВО", day: 2),
        ]).first?.key
        let b = ProjectCandidate.suggestions(for: [
            meeting("2", "МЕНТОРСТВО", day: 2), meeting("1", "Менторство", day: 1),
        ]).first?.key
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testСначалаТеЧтоПовторялисьЧаще() {
        let found = ProjectCandidate.suggestions(for: [
            meeting("1", "Редкий", series: "A", day: 1),
            meeting("2", "Редкий", series: "A", day: 2),
            meeting("3", "Частый", series: "B", day: 1),
            meeting("4", "Частый", series: "B", day: 2),
            meeting("5", "Частый", series: "B", day: 3),
        ])
        XCTAssertEqual(found.map(\.name), ["Частый", "Редкий"])
    }
}
