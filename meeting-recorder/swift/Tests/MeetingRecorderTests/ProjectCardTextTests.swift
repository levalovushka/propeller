import XCTest
@testable import PropellerPure

/// Подпись карточки и порядок сетки. Обе — правила, которые в теле вида пишутся
/// неправильно и незаметно: русский счёт склоняется по последним двум цифрам, а
/// «сколько дней назад» — календарная арифметика.
final class ProjectCardTextTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func daysBefore(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    // MARK: - Счёт

    func testСчётВстречСклоняетсяПоПоследнимДвумЦифрам() {
        let cases: [(Int, String)] = [
            (1, "1 встреча"), (2, "2 встречи"), (4, "4 встречи"), (5, "5 встреч"),
            // Подростки — все третьей формой, и это первое, что ломается,
            // если склонять по последней цифре.
            (11, "11 встреч"), (12, "12 встреч"), (14, "14 встреч"),
            (21, "21 встреча"), (22, "22 встречи"), (25, "25 встреч"),
            (101, "101 встреча"), (111, "111 встреч"),
        ]
        for (count, expected) in cases {
            XCTAssertEqual(ProjectCardText.meetingCount(count), expected, "\(count)")
        }
    }

    func testПроектБезВстречГоворитОбЭтомСловами() {
        XCTAssertEqual(ProjectCardText.meetingCount(0), "Пока нет встреч")
        // И тогда даты нет вовсе: датировать нечего.
        XCTAssertEqual(
            ProjectCardText.footer(meetings: 0, last: nil, now: now, calendar: calendar),
            "Пока нет встреч"
        )
    }

    // MARK: - Давность

    func testДавностьГоворитСловамиПокаЭтоЕщёОсмысленно() {
        let cases: [(Int, String)] = [
            (0, "Сегодня"), (1, "Вчера"), (2, "2 дня назад"), (5, "5 дней назад"),
            (7, "Неделю назад"), (13, "Неделю назад"), (14, "Давно"), (400, "Давно"),
        ]
        for (days, expected) in cases {
            XCTAssertEqual(
                ProjectCardText.recency(of: daysBefore(days), now: now, calendar: calendar),
                expected, "\(days)"
            )
        }
    }

    /// Встреча из будущего — это сбитые часы или импорт, а не пророчество. Тот
    /// же ответ, что даёт рельс: сегодня.
    func testВстречаИзБудущегоСчитаетсяСегодняшней() {
        XCTAssertEqual(
            ProjectCardText.recency(of: daysBefore(-3), now: now, calendar: calendar),
            "Сегодня"
        )
    }

    func testПодписьСобираетсяЦеликом() {
        XCTAssertEqual(
            ProjectCardText.footer(meetings: 12, last: daysBefore(1), now: now, calendar: calendar),
            "Вчера · 12 встреч"
        )
    }

    // MARK: - Порядок

    private func summary(_ name: String, meetings: Int = 1, last: Int?, archived: Bool = false,
                         created: Int = 100) -> ProjectSummary {
        ProjectSummary(
            project: Project(name: name, archived: archived, createdAt: daysBefore(created)),
            meetings: meetings,
            last: last.map(daysBefore)
        )
    }

    func testАктуальныеПервымиСчитаютсяПоПоследнейВстрече() {
        let cards = [
            summary("Старый", last: 30),
            summary("Свежий", last: 1),
            summary("Средний", last: 7),
        ]
        XCTAssertEqual(cards.ordered(by: .recent).map(\.project.name),
                       ["Свежий", "Средний", "Старый"])
    }

    /// Проект без встреч падает на дату создания. Иначе только что заведённый
    /// проект уезжал бы в самый низ — туда, где человек его не ищет.
    func testПроектБезВстречСтоитПоДатеСоздания() {
        let cards = [
            summary("С встречами", last: 10),
            summary("Только что заведён", meetings: 0, last: nil, created: 0),
        ]
        XCTAssertEqual(cards.ordered(by: .recent).first?.project.name, "Только что заведён")
    }

    /// Архивный проект стоит **в конце**, а не за пределами экрана: убрать его
    /// туда умеет меню карточки, и если карточки не будет, вернуть его будет
    /// нечем. Это дверь в один конец, и её здесь нет.
    func testАрхивныеУходятВКонецАНеИсчезают() {
        let cards = [
            summary("Архивный свежий", last: 1, archived: true),
            summary("Живой старый", last: 10),
            summary("Живой свежий", last: 2),
        ]
        for order in ProjectOrder.allCases {
            let names = cards.ordered(by: order).map(\.project.name)
            XCTAssertEqual(names.count, 3, order.rawValue)
            XCTAssertEqual(names.last, "Архивный свежий", order.rawValue)
        }
        // Порядок внутри живых при этом свой, а не «архивные в конце и всё».
        XCTAssertEqual(
            cards.ordered(by: .recent).map(\.project.name),
            ["Живой свежий", "Живой старый", "Архивный свежий"]
        )
        XCTAssertEqual(cards.live.map(\.project.name), ["Живой старый", "Живой свежий"])
    }

    func testПоАлфавитуНеЗависитОтРегистра() {
        let cards = [summary("яблоко", last: 1), summary("Апельсин", last: 2), summary("бук", last: 3)]
        XCTAssertEqual(cards.ordered(by: .alphabetical).map(\.project.name),
                       ["Апельсин", "бук", "яблоко"])
    }

    /// Сортировка, которая переставляет карточки между перерисовками, — это баг,
    /// а не мелочь: сетка мигает под курсором.
    func testПорядокУстойчивПриРавныхДатах() {
        let same = daysBefore(3)
        let cards = [
            ProjectSummary(project: Project(name: "Бета", createdAt: same), meetings: 1, last: same),
            ProjectSummary(project: Project(name: "Альфа", createdAt: same), meetings: 1, last: same),
        ]
        XCTAssertEqual(cards.ordered(by: .recent).map(\.project.name), ["Альфа", "Бета"])
        XCTAssertEqual(cards.reversed().ordered(by: .recent).map(\.project.name), ["Альфа", "Бета"])
    }
}
