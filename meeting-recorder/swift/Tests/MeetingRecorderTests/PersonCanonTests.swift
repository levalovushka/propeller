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

    /// Без транскрипта канон — подпись из ленты: подтвердить кириллическое
    /// написание нечем. С транскриптом это же имя останется русским
    /// (`testЛатиницаСоставаНеПереписываетРусскуюПрозу`).
    func testБезТранскриптаКанонЭтоПодписьИзЛенты() {
        let recap = "- Марина предложила два пути сотрудничества.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: roster),
            "- Marina предложила два пути сотрудничества.\n"
        )
    }

    /// Сверка исполнителя с составом не считает верное имя выдумкой — **и до
    /// замены тоже**, с 2026-08-28.
    ///
    /// Раньше этот тест утверждал обратное: «Марина» против ленточного «Marina
    /// Primer» была находкой, потому что сверка сравнивала сырые строки, и
    /// починка написания была обязана случиться **до** линтера. Из той одной
    /// строки выросла круговая правка в пайплайне — латиница до редактуры,
    /// кириллица после. Матчер линтера теперь зовёт `PersonCanon.fold`, алфавит
    /// в сверке не считается, и обе половины теста зелёные.
    func testСверкаСоСоставомНеСчитаетАлфавитВыдумкой() {
        let recap = "## Задачи\n- **Марина** — собрать репорты.\n"
        for text in [recap, PersonCanon.normalize(recap, roster: roster)] {
            let found = RecapLint.findings(recap: text, transcript: "", participants: roster)
            XCTAssertFalse(found.contains { $0.kind == .assigneeOutsideRoster }, text)
        }
        // Выдуманного исполнителя она по-прежнему находит.
        let ghost = RecapLint.findings(
            recap: "## Задачи\n- **Олег Петров** — собрать репорты.\n",
            transcript: "", participants: roster
        )
        XCTAssertTrue(ghost.contains { $0.kind == .assigneeOutsideRoster })
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

    /// Дефект, найденный владельцем в живом рекапе 2026-08-28. Модель пишет
    /// «Полина Кременец» — обе части кириллицей; состав знает «Polina
    /// Kremenets». «Полина» сворачивается в «polina» и совпадает, «Кременец» —
    /// в «kremenec» против «kremenets» и не совпадает. До правки в конспект
    /// уезжало «Polina Кременец»: один человек в двух алфавитах внутри одного
    /// имени, и написали это мы, а не модель.
    func testПолИмениНеПриводитсяКСоставу() {
        let out = PersonCanon.normalize(
            "## Задачи\n- **Полина Кременец** — написать заказчику.\n",
            roster: ["Polina Kremenets", "Левон"]
        )
        XCTAssertTrue(out.contains("**Полина Кременец**"), out)
        XCTAssertFalse(out.contains("Polina Кременец"))
    }

    /// И то же с фамилией, которую ASR услышал неверно: «Vlad Алодхин» при
    /// составе «Vlad Aldokhin» — половину чинить нельзя.
    func testНеузнаннаяФамилияОставляетИмяКакБыло() {
        let out = PersonCanon.normalize(
            "- **Влад Алодхин** — приехать на встречу.",
            roster: ["Vlad Aldokhin"]
        )
        XCTAssertTrue(out.contains("**Влад Алодхин**"), out)
        XCTAssertFalse(out.contains("Vlad Алодхин"))
    }

    /// Что правило не должно было сломать: одиночное имя по-прежнему приводится,
    /// и двухсловное — когда состав узнаёт **оба** слова.
    func testУзнанноеЦеликомИмяВсёЖеПриводится() {
        XCTAssertTrue(
            PersonCanon.normalize("- **Марина** — смета.", roster: ["Marina Primer"])
                .contains("**Marina**")
        )
        XCTAssertTrue(
            PersonCanon.normalize("- **Марина Primer** — смета.", roster: ["Marina Primer"])
                .contains("**Marina Primer**")
        )
    }

    // MARK: - Канон — кириллица, подтверждённая транскриптом

    /// Дефект, найденный владельцем в живом конспекте 2026-08-28: состав пришёл
    /// из Zoom латиницей, и **мы** переписывали русское «Полина уточняет» в
    /// «Polina» — тянули русский документ в латиницу.
    func testЛатиницаСоставаНеПереписываетРусскуюПрозу() {
        let out = PersonCanon.normalize(
            "- Polina уточняет вопрос, Vlad согласился.\n",
            roster: ["Polina Kremenets", "Vlad Aldokhin"],
            transcript: "Полина сказала, что Влад придёт."
        )
        XCTAssertEqual(out, "- Полина уточняет вопрос, Влад согласился.\n")
    }

    /// И в обратную сторону: русское написание не уезжает в латиницу.
    func testРусскоеИмяОстаётсяРусским() {
        XCTAssertEqual(
            PersonCanon.normalize(
                "- Полина уточняет вопрос.\n",
                roster: ["Polina Kremenets"],
                transcript: "Полина сказала."
            ),
            "- Полина уточняет вопрос.\n"
        )
    }

    /// Транскрипт — не украшение: без подтверждения написание остаётся
    /// ленточным. «Mikhail» → «Микхаил» свёртку проходит, а имени такого нет.
    func testБезПодтвержденияТранскриптомКанонОстаётсяЛенточным() {
        XCTAssertEqual(
            PersonCanon.normalize(
                "- Polina уточняет вопрос.\n",
                roster: ["Polina Kremenets"],
                transcript: "Речь про смету."
            ),
            "- Polina уточняет вопрос.\n"
        )
    }

    /// Фамилия, написанная моделью своим написанием: тот же человек, и он
    /// зовётся личным именем. Слово уходит — единственное место, где это бывает.
    func testФамилияСвоегоНаписанияСворачиваетсяВЛичноеИмя() {
        let transcript = "Полина сказала, что Влад придёт."
        let out = PersonCanon.normalize(
            "## Задачи\n- **Полина Кременец** — написать заказчику.\n"
                + "- **Влад Альдохин** — приехать.\n",
            roster: ["Polina Kremenets", "Vlad Aldokhin"],
            transcript: transcript
        )
        XCTAssertTrue(out.contains("**Полина** — написать"), out)
        XCTAssertTrue(out.contains("**Влад** — приехать"), out)
    }

    /// Заслонка того же правила: фамилию ASR услышал неверно («Алодхин» против
    /// «Aldokhin» — две общих буквы свёртки), и тогда имя остаётся как написано.
    func testНеузнаннаяФамилияНеСчитаетсяСвоимНаписанием() {
        let out = PersonCanon.normalize(
            "- **Влад Алодхин** — приехать на встречу.",
            roster: ["Vlad Aldokhin"],
            transcript: "Влад придёт."
        )
        XCTAssertTrue(out.contains("**Влад Алодхин**"), out)
    }

    /// И вторая заслонка: у однословного участника сравнивать не с чем, значит
    /// соседнее слово — не его фамилия и потеряться не может.
    func testСоседнееСловоНеСчитаетсяФамилиейОднословногоУчастника() {
        let out = PersonCanon.normalize(
            "- Левон Гант пересобрал график.",
            roster: ["Левон"],
            transcript: "Левон пересобрал Гант."
        )
        XCTAssertEqual(out, "- Левон Гант пересобрал график.")
    }

    /// Русский состав уже по канону: укорачивать «Борис Пример» до «Борис»
    /// значило бы терять фамилию без причины. Правило чинит алфавит, а не длину.
    func testРусскийСоставНеУкорачиваетсяДоЛичногоИмени() {
        let recap = "- **Борис Пример** проведёт опрос.\n"
        XCTAssertEqual(
            PersonCanon.normalize(recap, roster: roster, transcript: "Борис проведёт опрос."),
            recap
        )
    }
}
