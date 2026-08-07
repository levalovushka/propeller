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

    /// Ожидание, которое длиннее минуты, объясняют словами: «докачается
    /// модель» — это про завтра, а не про сейчас, и подменять эту строку
    /// текстом значит оставить человека гадать, чего ждут.
    func testДолгоеОжиданиеОбъясняютСловамиАНеПодменяютТекстом() {
        XCTAssertEqual(
            decide(hasTranscript: true, rest: .waiting(.model)),
            .nothing("Саммари появится, когда докачается модель")
        )
        XCTAssertEqual(
            decide(hasTranscript: true, rest: .waiting(.network)),
            .nothing("Ждём ответа сервиса")
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
