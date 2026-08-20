import XCTest
@testable import PropellerPure

/// Строка календаря в настройках. Тесты названы тем, что видит человек: у него
/// либо приезжают названия встреч, либо есть кнопка, которая это чинит.
final class CalendarAccessTests: XCTestCase {

    private func row(_ enabled: Bool, _ access: CalendarAccess) -> CalendarSettingsRow {
        .state(enabled: enabled, access: access)
    }

    func testВыключенныйКалендарьПредлагаютПодключить() {
        XCTAssertEqual(row(false, .notDetermined), .offer)
        XCTAssertEqual(row(false, .denied), .offer)
    }

    /// Выданное однажды разрешение не значит, что календарём пользуются:
    /// приложение о нём не спрашивало — значит строка предлагает, а не хвалится.
    func testРазрешениеБезВключенияВсёРавноПредложение() {
        XCTAssertEqual(row(false, .granted), .offer)
    }

    func testРаботающийКалендарьТолькоГалочка() {
        let state = row(true, .granted)
        XCTAssertEqual(state, .granted)
        XCTAssertTrue(state.showsCheckmark)
        XCTAssertNil(state.actionTitle)
        XCTAssertNil(state.subtitle)
    }

    /// Тот самый случай 2026-08-17: сменилась подпись сборки, грант TCC перестал
    /// совпадать с новой личностью приложения. Окно ещё покажется — значит
    /// спрашиваем сами.
    func testСлетевшийГрантСпрашиваютСами() {
        let state = row(true, .notDetermined)
        XCTAssertEqual(state, .ask)
        XCTAssertEqual(state.actionTitle, "Разрешить")
        XCTAssertFalse(state.opensSystemSettings)
        XCTAssertNotNil(state.subtitle)
    }

    /// После отказа окна не будет: единственный работающий путь — System
    /// Settings, и кнопка обязана вести туда, а не изображать повторный запрос.
    func testОтказВедётВСистемныеНастройки() {
        let state = row(true, .denied)
        XCTAssertEqual(state, .blocked)
        XCTAssertEqual(state.actionTitle, "Открыть доступ")
        XCTAssertTrue(state.opensSystemSettings)
    }

    /// Строка существует ради одного: сказать, что названий из календаря не
    /// будет. Молчащее сломанное состояние — это то, что чинится.
    func testКаждоеСломанноеСостояниеОбъясняетСебя() {
        for state in [row(true, .notDetermined), row(true, .denied)] {
            XCTAssertNotNil(state.subtitle, "\(state) молчит")
            XCTAssertNotNil(state.actionTitle, "\(state) без кнопки")
            XCTAssertFalse(state.showsCheckmark)
        }
    }
}
