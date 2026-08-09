import XCTest
@testable import PropellerPure

/// Что человек видит на месте саммари в ту минуту, пока модель его пишет.
final class SummaryColumnContentTests: XCTestCase {

    private func decide(
        hasSummary: Bool = false,
        hasTranscript: Bool = false,
        rest: MeetingRest = .waiting(.working)
    ) -> SummaryColumnContent {
        SummaryColumnContent.decide(
            hasSummary: hasSummary, hasTranscript: hasTranscript, rest: rest
        )
    }

    func testГотовоеСаммариИЕстьКолонка() {
        XCTAssertEqual(decide(hasSummary: true, hasTranscript: true), .summary)
        XCTAssertEqual(decide(hasSummary: true, rest: .done(.complete)), .summary)
    }

    /// То самое, ради чего файл: пока саммари пишется, человек продолжает
    /// читать расшифровку, а не сообщение о том, что саммари нет.
    func testПокаСаммариПишетсяВиднаРасшифровка() {
        XCTAssertEqual(decide(hasTranscript: true, rest: .waiting(.working)), .transcript)
        XCTAssertEqual(decide(hasTranscript: true, rest: .waiting(.queued)), .transcript)
    }

    /// Чем длиннее ожидание, тем **важнее** показать расшифровку, а не строку
    /// про него.
    ///
    /// Раньше было наоборот: у ожидания с именем — «докачается модель», «ждём
    /// сервиса» — колонка называла причину вместо текста. Решение 2026-08-09
    /// это развернуло, и вот чем. «Докачается модель» может стоять час; всё это
    /// время приложение отбирало готовую расшифровку, чтобы сообщить о
    /// ненаписанном саммари, — та же ошибка, которую этот файл однажды уже
    /// чинил для минуты между «расшифровали» и «суммировали», просто ценой в
    /// шестьдесят раз выше. Что идёт обработка и какая — говорит рельс.
    func testЧемДольшеЖдёмТемВажнееПоказатьТоЧтоУжеЕсть() {
        XCTAssertEqual(decide(hasTranscript: true, rest: .waiting(.model)), .transcript)
        XCTAssertEqual(decide(hasTranscript: true, rest: .waiting(.network)), .transcript)
    }

    /// Но только пока чего-то ждут. Причина остановки расшифровкой не
    /// подменяется: у доведённой встречи следующей ступени нет, и «показать
    /// пока предыдущую» нечего.
    func testБезРаботыВпередиПричинуНеПодменяютТекстом() {
        XCTAssertEqual(
            decide(hasTranscript: true, rest: .done(.noSpeech)),
            .nothing("Никто ничего не сказал")
        )
    }

    func testБезРасшифровкиНечегоПоказатьИТакИСказано() {
        XCTAssertEqual(decide(rest: .waiting(.working)),
                       .nothing(SummaryColumnContent.defaultNothing))
    }

    /// Встреча остановилась насовсем — колонка говорит почему, а не подменяет
    /// причину текстом: причина и есть то, что надо прочитать.
    func testКогдаДальшеНичегоНеБудетКолонкаГоворитПочему() {
        XCTAssertEqual(
            decide(hasTranscript: true, rest: .done(.summariesOff)),
            .nothing("Саммари выключено в\u{00A0}настройках")
        )
        XCTAssertEqual(
            decide(hasTranscript: true, rest: .done(.noSpeech)),
            .nothing("Никто ничего не сказал")
        )
    }

    /// Готовая встреча без файла саммари — состояние, в котором приложения не
    /// бывает (инвариант I9), но правило обязано быть определено и здесь.
    func testДоведённаяВстречаБезСаммариНеПоказываетРасшифровкуМолча() {
        XCTAssertEqual(
            decide(hasTranscript: true, rest: .done(.complete)),
            .nothing(SummaryColumnContent.defaultNothing)
        )
    }
}
