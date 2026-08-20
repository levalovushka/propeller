import XCTest
@testable import PropellerPure

/// Онбординг стал одной плашкой, а его вопросы — блоком в рельсе. Тесты
/// названы тем, что видит человек: блок не должен появиться там, где вопрос уже
/// задавали, и не должен исчезнуть, пока на него не ответили.
final class SetupPromptTests: XCTestCase {

    private func step(
        setupCompleted: Bool = true,
        calendarGranted: Bool = false,
        calendarAsked: Bool = false,
        knownName: String = "",
        nameAsked: Bool = false,
        offeredClient: MCPClient? = nil,
        claudeAsked: Bool = false
    ) -> SetupPrompt? {
        SetupPromptMachine.step(
            setupCompleted: setupCompleted,
            calendarGranted: calendarGranted,
            calendarAsked: calendarAsked,
            knownName: knownName,
            nameAsked: nameAsked,
            offeredClient: offeredClient,
            claudeAsked: claudeAsked
        )
    }

    // MARK: - Порядок

    func testНоваяУстановкаСначалаСпрашиваетКалендарь() {
        XCTAssertEqual(step(), .calendar)
    }

    func testПослеКалендаряСпрашиваетИмя() {
        XCTAssertEqual(step(calendarAsked: true), .name)
    }

    func testКогдаОтвеченоВсёБлокаНет() {
        XCTAssertNil(step(calendarAsked: true, knownName: "Лёва"))
        XCTAssertNil(step(calendarAsked: true, knownName: "Лёва",
                          offeredClient: .claudeDesktop, claudeAsked: true))
    }

    /// Клод идёт последним и только когда есть что предлагать: без Claude
    /// Desktop это была бы реклама чужого приложения в подошве рельса.
    func testПослеИмениСпрашиваетПроКлодаЕслиОнЕсть() {
        XCTAssertEqual(step(calendarAsked: true, knownName: "Лёва", offeredClient: .claudeDesktop), .claude)
    }

    func testБезКлодаТретьегоВопросаНет() {
        XCTAssertNil(step(calendarAsked: true, knownName: "Лёва", offeredClient: nil))
    }

    /// Тот же уговор, что у календаря: шаг тратится нажатием. Не записался
    /// конфиг — про это скажет ячейка в настройках, а не вернувшийся вопрос.
    func testНажатиеПодключитьЗакрываетШагПроКлода() {
        XCTAssertNil(step(calendarAsked: true, knownName: "Лёва",
                          offeredClient: .claudeDesktop, claudeAsked: true))
    }

    /// Порядок держится лесенкой: пока имя не названо, про Клода не спрашивают,
    /// даже если он стоит.
    func testКлодНеПеребиваетПредыдущиеВопросы() {
        XCTAssertEqual(step(offeredClient: .claudeDesktop), .calendar)
        XCTAssertEqual(step(calendarAsked: true, offeredClient: .claudeDesktop), .name)
    }

    /// Пока плашка настройки на экране, рельса не видно вовсе — но состояние не
    /// должно зависеть от того, кто на что смотрит.
    func testДоНастройкиБлокаНет() {
        XCTAssertNil(step(setupCompleted: false))
    }

    // MARK: - Что закрывает вопрос

    /// «Подключить» тратит шаг само по себе. Что ответит система — дело человека
    /// и календаря; спросить второй раз значит превратить предложение в нытьё.
    func testНажатиеПодключитьЗакрываетШагДажеБезДоступа() {
        XCTAssertEqual(step(calendarGranted: false, calendarAsked: true), .name)
    }

    /// Обновление с 1.14: имя спрашивали своим экраном, календарь — своим. Оба
    /// вопроса уже заданы, и блок не должен здороваться с тем, кто давно внутри.
    func testОбновлениеСВыданнымКалендарёмИИменемНеСпрашиваетНичего() {
        XCTAssertNil(step(calendarGranted: true, knownName: "Лёва"))
    }

    func testВыданныйКалендарьЗакрываетШагБезНажатия() {
        XCTAssertEqual(step(calendarGranted: true), .name)
    }

    /// Пробелы — не имя. Иначе ⏎ по пустому полю закрыл бы вопрос ничем, и
    /// каждая будущая расшифровка молча ушла бы на имя учётной записи.
    func testПробелыНеСчитаютсяОтветом() {
        XCTAssertEqual(step(calendarAsked: true, knownName: "   \n "), .name)
    }

    /// Решение по продукту: кнопки «пропустить» нет. Блок ничего не держит —
    /// запись, расшифровка и саммари идут поверх него, — поэтому он просто ждёт.
    func testБезОтветаБлокНеУходитСамПоСебе() {
        for _ in 0..<3 {
            XCTAssertEqual(step(), .calendar)
        }
    }

    // MARK: - Слова

    func testСчётчикВсегдаИзТрёх() {
        XCTAssertEqual(SetupPrompt.calendar.counter, "1/3")
        XCTAssertEqual(SetupPrompt.name.counter, "2/3")
        XCTAssertEqual(SetupPrompt.claude.counter, "3/3")
        XCTAssertEqual(SetupPrompt.total, SetupPrompt.allCases.count)
    }

    /// Счётчик не сжимается, когда календарь уже выдан: шаг имени остаётся
    /// вторым из двух, а не становится «1/1».
    func testСчётчикНеЗависитОтТогоЧтоУжеОтвечено() {
        XCTAssertEqual(step(calendarGranted: true)?.counter, "2/3")
        // Одинокое «3/3» у того, кто ответил всё остальное, — принято как есть:
        // индекс закреплён, чтобы шаг не врал про длину блока.
        XCTAssertEqual(
            step(calendarGranted: true, knownName: "Лёва", offeredClient: .claudeDesktop)?.counter, "3/3"
        )
    }

    /// У каждого шага ровно одна форма ответа — кнопка или поле. И то и другое
    /// сразу означало бы два способа ответить на один вопрос; ни одного —
    /// вопрос, на который нельзя ответить.
    func testУКаждогоШагаРовноОднаФормаОтвета() {
        for prompt in SetupPrompt.allCases {
            let hasButton = prompt.actionTitle != nil
            let hasField = prompt.fieldPlaceholder != nil
            XCTAssertTrue(hasButton != hasField,
                          "\(prompt.rawValue): кнопка=\(hasButton), поле=\(hasField)")
        }
    }

    func testУКаждогоШагаЕстьЧтоСказать() {
        for prompt in SetupPrompt.allCases {
            XCTAssertFalse(prompt.title.isEmpty)
            XCTAssertFalse(prompt.subtitle.isEmpty)
        }
    }

    // MARK: - Имя, стёртое в настройках

    /// Поле в настройках позволяет имя убрать — это ответ «подписывай системным
    /// именем», а не «спроси меня снова». Вернувшийся вопрос читался бы как
    /// приложение, забывшее собственный разговор.
    func testСтёртоеВНастройкахИмяНеВозвращаетВопрос() {
        XCTAssertNil(step(calendarAsked: true, knownName: "", nameAsked: true))
    }

    /// Обратная сторона: пока имя не спрашивали, пустота — это вопрос.
    func testБезФлагаПустоеИмяВсёЕщёСпрашивают() {
        XCTAssertEqual(step(calendarAsked: true, knownName: "", nameAsked: false), .name)
    }

    /// Порядок не ломается: закрытое имя пропускает шаг вперёд, к Клоду.
    func testСтёртоеИмяПропускаетКСледующемуВопросу() {
        XCTAssertEqual(
            step(calendarAsked: true, knownName: "", nameAsked: true,
                 offeredClient: .claudeDesktop),
            .claude
        )
    }
}
