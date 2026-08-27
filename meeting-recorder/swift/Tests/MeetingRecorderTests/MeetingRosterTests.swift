import XCTest
@testable import PropellerPure

/// Состав встречи — то, что откроется под чипом «6 человек».
///
/// Имена в образцах — из живых трасс владельца в том виде, в каком их пишет
/// Zoom («Levon Lobanov», «Polina Kremenets»): именно на этой паре написаний
/// ломается свёртка, если её забыть.
final class MeetingRosterTests: XCTestCase {

    private func names(_ input: MeetingRoster.Input) -> [String] {
        MeetingRoster.rows(input).map(\.name)
    }

    // MARK: - Владелец

    func testВладелецПервыйИНеУдаляется() {
        let rows = MeetingRoster.rows(.init(
            call: ["Polina Kremenets", "Levon Lobanov"],
            ownerName: "Левон",
            ownerZoomName: "Levon Lobanov"
        ))
        XCTAssertEqual(rows.first?.name, "Левон")
        XCTAssertEqual(rows.first?.origin, .owner)
        XCTAssertFalse(rows.first?.isRemovable ?? true)
        XCTAssertTrue(rows.dropFirst().allSatisfy(\.isRemovable))
    }

    func testБезИмениВладелецВсёРавноРяд() {
        // Вопрос об имени можно не проходить — это законное состояние, и ряд
        // тогда подписан заглушкой микрофонного пути, а не пропадает.
        let rows = MeetingRoster.rows(.init(spoken: ["Я", "Собеседник"]))
        XCTAssertEqual(rows.map(\.name), ["Я", "Собеседник"])
        XCTAssertEqual(rows.first?.origin, .owner)
    }

    func testПлиткаВладельцаНеСтановитсяВторымРядом() {
        // Замер: в каждой из 19 трасс лежит «Levon Lobanov», а в префах —
        // «Левон». Свёртка их не соединяет, поэтому Zoom-имя передаётся отдельно.
        XCTAssertEqual(
            names(.init(
                call: ["Levon Lobanov", "Ilyas Aitkulov"],
                ownerName: "Левон",
                ownerZoomName: "Levon Lobanov"
            )),
            ["Левон", "Ilyas Aitkulov"]
        )
    }

    func testБезЯкоряZoomИмяВладельцаЕдётОтдельнымРядом() {
        // Названная цена: пока `ownerZoomName` не выучен, владелец в списке
        // дважды. Лучше знать это тестом, чем на живой встрече.
        XCTAssertEqual(
            names(.init(call: ["Levon Lobanov"], ownerName: "Левон")),
            ["Левон", "Levon Lobanov"]
        )
    }

    func testВладельцаУбратьНельзя() {
        let rows = MeetingRoster.rows(.init(
            spoken: ["Левон", "Speaker 2"],
            ownerName: "Левон",
            removed: ["Левон", "Speaker 2"]
        ))
        XCTAssertEqual(rows.map(\.name), ["Левон"])
    }

    // MARK: - Лестница источников

    func testПорядокПлитокПоВесуСохраняется() {
        XCTAssertEqual(
            names(.init(
                call: ["Ilyas Aitkulov", "Aleksandra Nikandrova", "Милена Мордашева"],
                ownerName: "Левон"
            )),
            ["Левон", "Ilyas Aitkulov", "Aleksandra Nikandrova", "Милена Мордашева"]
        )
    }

    func testКластерыЭтоРяды() {
        // За `Speaker 2` стоит живой человек, чьего имени мы не знаем. Не ряд —
        // значит его нечем назвать одним движением.
        let rows = MeetingRoster.rows(.init(
            spoken: ["Левон", "Speaker 2", "Speaker 3"], ownerName: "Левон"
        ))
        XCTAssertEqual(rows.map(\.name), ["Левон", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(rows.dropFirst().map(\.origin), [.cluster, .cluster])
        XCTAssertEqual(rows.dropFirst().map(\.label), ["Speaker 2", "Speaker 3"])
    }

    func testДваНаписанияОдногоЧеловекаСходятсяВОдинРяд() {
        // Плитка говорит «Polina Kremenets», лента — «Полина». Один ряд, и
        // написание из ленты: читатель должен найти его в расшифровке глазами.
        let rows = MeetingRoster.rows(.init(
            call: ["Polina Kremenets"],
            spoken: ["Левон", "Полина"],
            ownerName: "Левон"
        ))
        XCTAssertEqual(rows.map(\.name), ["Левон", "Полина"])
        XCTAssertEqual(rows.last?.label, "Полина")
    }

    func testФамилияСшиваетДваАлфавита() {
        // «Alexander» и «Александр» — перевод имени, свёртка их не соединит. Но
        // фамилия транслитерируется одинаково, и слово «Яшин» принадлежит ровно
        // одной плитке — этого достаточно. То же, чем `PersonCanon` ловит
        // «Марину» против ленточной «Marina Primer».
        XCTAssertEqual(
            names(.init(call: ["Alexander Yashin"], spoken: ["Александр Яшин"])),
            ["Я", "Александр Яшин"]
        )
    }

    func testПереводИмениБезФамилииНеСшивается() {
        // Названная граница: сшивать здесь нечем, и два ряда честнее одного
        // угаданного. Разводит их человек.
        XCTAssertEqual(
            names(.init(call: ["Alexander"], spoken: ["Александр"])),
            ["Я", "Alexander", "Александр"]
        )
    }

    func testОбщееИмяДвухУчастниковНеСклеиваетИх() {
        // «Александр» принадлежит двум плиткам сразу — голое слово не значит ни
        // того, ни другого, и ряд остаётся своим.
        XCTAssertEqual(
            names(.init(
                call: ["Александр Яшин", "Александр Образцов"], spoken: ["Александр"]
            )),
            ["Я", "Александр Яшин", "Александр Образцов", "Александр"]
        )
    }

    func testДобавленныйРукамиРядБезПодписиВЛенте() {
        let rows = MeetingRoster.rows(.init(
            spoken: ["Левон"], ownerName: "Левон", added: ["Арина Солдатёнкова"]
        ))
        XCTAssertEqual(rows.last?.origin, .manual)
        XCTAssertNil(rows.last?.label)
    }

    func testУбранноеНеВозвращается() {
        XCTAssertEqual(
            names(.init(
                call: ["Ilyas Aitkulov", "Polina Kremenets"],
                ownerName: "Левон", ownerZoomName: "Levon Lobanov",
                removed: ["Ilyas Aitkulov"]
            )),
            ["Левон", "Polina Kremenets"]
        )
    }

    func testКлючПлейсхолдераРазличаетНомера() {
        // Свёртка выбрасывает цифры: без отдельного ключа убранный второй
        // кластер уносил бы третий.
        XCTAssertNotEqual(MeetingRoster.key("Speaker 2"), MeetingRoster.key("Speaker 3"))
        XCTAssertEqual(MeetingRoster.key("Полина"), MeetingRoster.key("Polina"))
    }

    // MARK: - Приглашённые: запас, а не состав

    func testПриглашённыеНеРядыКогдаЕстьКластеры() {
        // Решение владельца: список про участников. Показать оба значит
        // показать «Полину» и `Speaker 3`, возможно, одного человека дважды.
        XCTAssertEqual(
            names(.init(
                spoken: ["Левон", "Speaker 2", "Speaker 3"],
                invited: ["Полина Кременец", "Владислав Шукуров", "Арина Солдатёнкова"],
                ownerName: "Левон"
            )),
            ["Левон", "Speaker 2", "Speaker 3"]
        )
    }

    func testПриглашённыеСтановятсяРядамиКогдаБольшеНечегоПоказать() {
        // Пятая ступень: из звонилки не приехало ничего, лента дала только
        // владельца — тогда приглашённые единственное, что о составе известно.
        XCTAssertEqual(
            names(.init(
                spoken: ["Левон"],
                invited: ["Полина Кременец", "Владислав Шукуров"],
                ownerName: "Левон"
            )),
            ["Левон", "Полина Кременец", "Владислав Шукуров"]
        )
    }

    func testРассылкаНеДаётНиРядовНиКандидатов() {
        // Приглашение на 107 адресов в живом архиве есть, и рассылка — не встреча.
        let crowd = (1...20).map { "Гость \($0) <g\($0)@example.com>" }
        let input = MeetingRoster.Input(spoken: ["Левон"], invited: crowd, ownerName: "Левон")
        XCTAssertEqual(names(input), ["Левон"])
        XCTAssertEqual(MeetingRoster.candidates(input), [])
        XCTAssertFalse(MeetingRoster.invitedUsable(crowd))
    }

    // MARK: - Кандидаты

    func testКандидатыЭтоПриглашённыеМинусУжеСтоящиеВСоставе() {
        let input = MeetingRoster.Input(
            call: ["Polina Kremenets"],
            spoken: ["Левон", "Полина", "Speaker 3"],
            invited: ["Полина Кременец", "Владислав Шукуров"],
            ownerName: "Левон"
        )
        // «Полина Кременец» свёрткой не совпадает с «Полина» — фамилия делает
        // ключ другим, и предложить её честно: склеить два написания одного
        // человека это отдельное действие, а не побочный эффект показа списка.
        XCTAssertEqual(
            MeetingRoster.candidates(input, known: ["Арина Солдатёнкова", "Левон"]),
            ["Полина Кременец", "Владислав Шукуров", "Арина Солдатёнкова"]
        )
    }

    func testПлейсхолдерВКандидатыНеИдёт() {
        XCTAssertEqual(
            MeetingRoster.candidates(
                .init(spoken: ["Левон"], ownerName: "Левон"),
                known: ["Speaker 2", "Собеседник", "Арина"]
            ),
            ["Арина"]
        )
    }

    func testБезЕдиногоСледаСоставаНетВовсе() {
        // Владелец — единственный ряд не из данных, и без этой отсечки он
        // появлялся бы у встречи, которая ещё расшифровывается: чип «1 человек»
        // на пустой панели обещает состав там, где его не считали.
        XCTAssertEqual(names(.init(ownerName: "Левон")), [])
        // Одного приглашённого достаточно, чтобы встреча уже о чём-то говорила.
        XCTAssertEqual(
            names(.init(invited: ["Полина Кременец"], ownerName: "Левон")),
            ["Левон", "Полина Кременец"]
        )
    }
}
