import XCTest
@testable import PropellerPure

/// Состав проекта собирается из двух источников, потому что поля «участники» у
/// встречи нет. Каждый случай ниже — про то, чего этот сбор **не** должен
/// придумать.
final class ProjectRosterTests: XCTestCase {

    private func meeting(_ id: String, speakers: [String] = [], invited: [String] = [])
        -> ProjectRoster.Meeting {
        ProjectRoster.Meeting(id: id, speakers: speakers, invited: invited)
    }

    func testЧеловекСчитаетсяПоВстречамАНеПоРепликам() {
        // Один и тот же человек назван в двух встречах — значит две, а не
        // столько, сколько раз он открыл рот.
        let people = ProjectRoster.roster(of: [
            meeting("1", speakers: ["Левон", "Левон", "Аня"]),
            meeting("2", speakers: ["Левон"]),
        ])
        XCTAssertEqual(people.map(\.name), ["Левон", "Аня"])
        XCTAssertEqual(people.first?.meetings, 2)
        XCTAssertEqual(people.last?.meetings, 1)
    }

    func testСначалаТеКтоЧащеПотомПоАлфавиту() {
        let people = ProjectRoster.roster(of: [
            meeting("1", speakers: ["Яна", "Борис", "Аня"]),
            meeting("2", speakers: ["Борис"]),
        ])
        XCTAssertEqual(people.map(\.name), ["Борис", "Аня", "Яна"])
    }

    /// «Марина» из ленты и «Marina» из календаря — один человек. Свёртка та же,
    /// которой конспект приводит имена к составу ленты.
    func testДваНаписанияОдногоИмениСходятсяВОдногоЧеловека() {
        let people = ProjectRoster.roster(of: [
            meeting("1", speakers: ["Марина"], invited: ["Marina"]),
        ])
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.meetings, 1)
    }

    /// Побеждает написание из ленты: читатель должен найти этого человека в
    /// расшифровке глазами.
    func testПобеждаетНаписаниеКоторымЧеловекаНазвалиГолосом() {
        let spokenFirst = ProjectRoster.roster(of: [meeting("1", speakers: ["Марина"], invited: ["Marina"])])
        XCTAssertEqual(spokenFirst.first?.name, "Марина")
        // И наоборот: кого записали первым, на ответ не влияет — сначала
        // приглашённый, потом та же строка голосом.
        let invitedFirst = ProjectRoster.roster(of: [
            meeting("1", invited: ["Marina"]),
            meeting("2", speakers: ["Марина"]),
        ])
        XCTAssertEqual(invitedFirst.first?.name, "Марина")
    }

    /// «Приглашён» и «был» — разные факты. Склеить их значило бы сказать про
    /// человека то, чего архив не знает.
    func testПриглашённыйНеСтановитсяУчастником() {
        let people = ProjectRoster.roster(of: [meeting("1", speakers: ["Левон"], invited: ["Аня"])])
        XCTAssertEqual(people.first(where: { $0.name == "Левон" })?.spoke, true)
        XCTAssertEqual(people.first(where: { $0.name == "Аня" })?.spoke, false)
        XCTAssertEqual(
            ProjectRoster.subtitle(for: people.first(where: { $0.name == "Аня" })!),
            "Приглашён · 1 встреча"
        )
        XCTAssertEqual(
            ProjectRoster.subtitle(for: people.first(where: { $0.name == "Левон" })!),
            "1 встреча"
        )
    }

    /// Тот, кто в первой встрече только числился приглашённым, а во второй
    /// заговорил, — участник: «был» сильнее «приглашён».
    func testЗаговорившийПерестаётБытьТолькоПриглашённым() {
        let people = ProjectRoster.roster(of: [
            meeting("1", invited: ["Аня"]),
            meeting("2", speakers: ["Аня"]),
        ])
        XCTAssertEqual(people.first?.spoke, true)
        XCTAssertEqual(people.first?.meetings, 2)
    }

    func testПустоеИПробельноеИмяНеЧеловек() {
        XCTAssertTrue(ProjectRoster.roster(of: [meeting("1", speakers: ["", "   "], invited: ["\n"])]).isEmpty)
    }

    func testПустойПроектДаётПустойСостав() {
        XCTAssertTrue(ProjectRoster.roster(of: []).isEmpty)
        XCTAssertTrue(ProjectRoster.roster(of: [meeting("1")]).isEmpty)
    }

    /// Заголовок встречи третьим источником не берётся, и это видно по тому,
    /// что состав такой встречи пуст: вытащить «Даней» из «1×1 с Даней» значило
    /// бы завести участника в творительном падеже.
    func testНазваниеВстречиИсточникомНеЯвляется() {
        // `Meeting` его и не принимает — проверка держит эту границу на месте.
        let people = ProjectRoster.roster(of: [meeting("1")])
        XCTAssertTrue(people.isEmpty)
    }

    // MARK: - Вкладки

    func testУВкладокЕстьИмяИПерваяИзНихПервая() {
        XCTAssertEqual(ProjectTab.entry, .meetings)
        XCTAssertEqual(ProjectTab.allCases.first, .meetings)
        for tab in ProjectTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, tab.rawValue)
        }
    }

    /// Кадр галереи появляется от того, что случай появился в типе, а не от
    /// того, что кто-то вспомнил про галерею.
    func testКаждаяВкладкаПопадаетВКаталогКадров() {
        let ids = Set(UIStateCatalog.allScreenIDs)
        for tab in ProjectTab.allCases {
            XCTAssertTrue(ids.contains("project-\(tab.rawValue)"), tab.rawValue)
        }
        XCTAssertTrue(ids.contains("projects-list"))
        XCTAssertTrue(ids.contains("projects-empty"))
    }

    // MARK: - Первая строка встречи

    func testСтрокаВстречиНазываетЧислоАНеЧас() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 22
        components.hour = 14; components.minute = 20
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))!

        XCTAssertEqual(
            ProjectCardText.meetingLine(date: date, duration: 45 * 60, now: now, calendar: calendar),
            "22 августа · 45 мин"
        )
        // Другой год — год назван: «22 августа» без него читается как этот.
        let older = calendar.date(from: DateComponents(year: 2025, month: 8, day: 22))!
        XCTAssertTrue(
            ProjectCardText.meetingLine(date: older, duration: 0, now: now, calendar: calendar)
                .hasSuffix("2025")
        )
    }

    /// Длительность — тем же правилом, что в рельсе: одна встреча не может быть
    /// «95 мин» в списке проекта и «1 ч 35 мин» в списке дня.
    func testДлительностьСчитаетсяТемЖеПравиломЧтоВРельсе() {
        let date = Date(timeIntervalSince1970: 1_787_000_000)
        XCTAssertTrue(
            ProjectCardText.meetingLine(date: date, duration: 95 * 60, now: date)
                .hasSuffix(SidebarMeta.durationText(95 * 60))
        )
    }
}
