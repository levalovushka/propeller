import XCTest
@testable import PropellerPure

/// Случаи взяты из живого конспекта встречи `20260820_160014` — первой, где
/// имена в ленту принёс журнал окна Zoom: там модель написала «Арина
/// Soldatenkova», хотя лента подписана «Arina Soldatenkova».
final class PersonCanonTests: XCTestCase {

    private let roster = ["Arina Soldatenkova", "Вячеслав Киржаев", "Левон"]

    func testПолуперевёрнутоеИмяСтановитсяНаписаниемИзСостава() {
        let recap = "## Задачи\n- **Левон и Арина Soldatenkova**: поделиться планами.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: roster),
            "## Задачи\n- **Левон и Arina Soldatenkova**: поделиться планами.\n"
        )
    }

    func testОдноИмяБезФамилииТожеПриводитсяКСоставу() {
        let recap = "- Арина предложила два пути сотрудничества.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: roster),
            "- Arina предложила два пути сотрудничества.\n"
        )
    }

    /// Ради этого всё и делается: сверка исполнителя с составом перестаёт
    /// считать верное имя выдумкой.
    ///
    /// Случай именно такой — имя целиком в другом алфавите: сверка ищет хотя бы
    /// один совпавший токен, поэтому «Арина Soldatenkova» проходит её за счёт
    /// фамилии, а «Арина» против «Arina Soldatenkova» не проходит вовсе.
    func testПослеЗаменыИсполнительПроходитСверкуССоставом() {
        let recap = "## Задачи\n- **Арина** — собрать репорты.\n"
        let before = RecapLint.findings(recap: recap, transcript: "", participants: roster)
        XCTAssertTrue(before.contains { $0.kind == .assigneeOutsideRoster })

        let after = RecapLint.findings(
            recap: PersonCanon.normalize(recap, roster: roster),
            transcript: "",
            participants: roster
        )
        XCTAssertFalse(after.contains { $0.kind == .assigneeOutsideRoster })
    }

    /// Косвенный падеж не трогается: «согласовать с Arina» — не по-русски, а
    /// «Арине» → «Arina» ломает фразу. Это работа редактора, не замены.
    func testКосвенныйПадежОстаётсяКакНаписан() {
        let recap = "- Левон передал документы Арине после встречи.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: roster), recap)
    }

    /// Разница в одной заглавной букве — не разнописание. Zoom-имя «костя»
    /// строчное, и опустить букву посреди предложения значило бы починить
    /// сверку ценой опечатки.
    func testРегистрНеПравится() {
        let recap = "- Костя показал макет.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: ["костя"]), recap)
    }

    /// Перевод имени — не написание. «Alexander» против «Александр» остаётся
    /// редактору: замена, которая это сшивает, начнёт сшивать и разных людей.
    func testПереводИмениНеСчитаетсяТемЖеНаписанием() {
        let recap = "- Alexander согласовал форму.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: ["Александр Яшин"]), recap)
    }

    func testПустойСоставОставляетТекстКакЕсть() {
        let recap = "## Итог\nВстреча про найм.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: []), recap)
    }

    /// Лента, где журнал молчал, — это `Speaker N`; такой «состав» в промпт не
    /// попадает и здесь тоже ничего не значит.
    func testМеткиДорожекНеСтановятсяКанономИмени() {
        let transcript = "[Speaker S1] [00:12]\nПривет.\n[Левон] [00:20]\nПривет.\n"
        let participants = RecapDocument.participants(fromTranscript: transcript)
        XCTAssertEqual(participants, ["Левон"])
        let recap = "- Speaker S1 предложил перенести встречу.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: participants), recap)
    }

    /// Двое с одинаковой свёрткой — ключ выбрасывается: угаданное имя хуже
    /// разнописания.
    func testОдинаковаяСвёрткаУДвоихНичегоНеМеняет() {
        let recap = "- Арина уточнит смету.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: ["Arina Soldatenkova", "Арина Петрова"]),
            recap
        )
    }

    func testФамилииРазныхЛюдейНеСклеиваются() {
        let recap = "- **Вячеслав Киржаев** проведёт опрос.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: roster), recap)
    }

    func testСвёрткаСшиваетАлфавитыИНеСшиваетРазныеИмена() {
        XCTAssertEqual(PersonCanon.fold("Арина"), PersonCanon.fold("Arina"))
        XCTAssertEqual(PersonCanon.fold("Киржаев"), PersonCanon.fold("Kirzhaev"))
        XCTAssertNotEqual(PersonCanon.fold("Арина"), PersonCanon.fold("Ирина"))
    }
}
