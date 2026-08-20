import XCTest
@testable import PropellerPure

/// Случаи взяты из живого конспекта встречи `20260820_160014` — первой, где
/// имена в ленту принёс журнал окна Zoom: там модель написала «Марина
/// Primer», хотя лента подписана «Marina Primer».
final class PersonCanonTests: XCTestCase {

    private let roster = ["Marina Primer", "Борис Пример", "Левон"]

    func testПолуперевёрнутоеИмяСтановитсяНаписаниемИзСостава() {
        let recap = "## Задачи\n- **Левон и Марина Primer**: поделиться планами.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: roster),
            "## Задачи\n- **Левон и Marina Primer**: поделиться планами.\n"
        )
    }

    func testОдноИмяБезФамилииТожеПриводитсяКСоставу() {
        let recap = "- Марина предложила два пути сотрудничества.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: roster),
            "- Marina предложила два пути сотрудничества.\n"
        )
    }

    /// Ради этого всё и делается: сверка исполнителя с составом перестаёт
    /// считать верное имя выдумкой.
    ///
    /// Случай именно такой — имя целиком в другом алфавите: сверка ищет хотя бы
    /// один совпавший токен, поэтому «Марина Primer» проходит её за счёт
    /// фамилии, а «Марина» против «Marina Primer» не проходит вовсе.
    func testПослеЗаменыИсполнительПроходитСверкуССоставом() {
        let recap = "## Задачи\n- **Марина** — собрать репорты.\n"
        let before = RecapLint.findings(recap: recap, transcript: "", participants: roster)
        XCTAssertTrue(before.contains { $0.kind == .assigneeOutsideRoster })

        let after = RecapLint.findings(
            recap: PersonCanon.normalize(recap, roster: roster),
            transcript: "",
            participants: roster
        )
        XCTAssertFalse(after.contains { $0.kind == .assigneeOutsideRoster })
    }

    /// Косвенный падеж не трогается: «согласовать с Marina» — не по-русски, а
    /// «Марине» → «Marina» ломает фразу. Это работа редактора, не замены.
    func testКосвенныйПадежОстаётсяКакНаписан() {
        let recap = "- Левон передал документы Марине после встречи.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: roster), recap)
    }

    /// Разница в одной заглавной букве — не разнописание. Zoom-имя «боря»
    /// строчное, и опустить букву посреди предложения значило бы починить
    /// сверку ценой опечатки.
    func testРегистрНеПравится() {
        let recap = "- Боря показал макет.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: ["боря"]), recap)
    }

    /// Перевод имени — не написание. «Alexander» против «Александр» остаётся
    /// редактору: замена, которая это сшивает, начнёт сшивать и разных людей.
    func testПереводИмениНеСчитаетсяТемЖеНаписанием() {
        let recap = "- Alexander согласовал форму.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: ["Пётр Пример"]), recap)
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
        let recap = "- Марина уточнит смету.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: ["Marina Primer", "Марина Петрова"]),
            recap
        )
    }

    func testФамилииРазныхЛюдейНеСклеиваются() {
        let recap = "- **Борис Пример** проведёт опрос.\n"
        XCTAssertEqual(PersonCanon.normalize(recap, roster: roster), recap)
    }

    func testСвёрткаСшиваетАлфавитыИНеСшиваетРазныеИмена() {
        XCTAssertEqual(PersonCanon.fold("Марина"), PersonCanon.fold("Marina"))
        XCTAssertEqual(PersonCanon.fold("Пример"), PersonCanon.fold("Primer"))
        XCTAssertNotEqual(PersonCanon.fold("Марина"), PersonCanon.fold("Ирина"))
    }
}
