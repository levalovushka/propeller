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

    /// Причина остановки не теряется — и не потому, что правило её бережёт, а
    /// потому, что её случай выглядит иначе.
    ///
    /// «Никто ничего не сказал» ставится только там, где расшифровка пуста:
    /// каждое место, объявляющее `.noSpeech`, стоит за проверкой
    /// `transcript?.isEmpty == false`. Значит подменять эту строку нечем — и
    /// правилу не нужна ветка, которая бы её защищала.
    func testВстречаБезРечиГоворитПочемуПотомуЧтоПоказатьЕйНечего() {
        XCTAssertEqual(
            decide(hasTranscript: false, rest: .done(.noSpeech)),
            .nothing("Никто ничего не сказал")
        )
    }

    func testБезРасшифровкиНечегоПоказатьИТакИСказано() {
        XCTAssertEqual(decide(rest: .waiting(.working)),
                       .nothing(SummaryColumnContent.defaultNothing))
    }

    /// Доведённая встреча без файла саммари — не экран, а работа для бэкфилла.
    ///
    /// Колонке тут решать нечего: она показывает самое глубокое, что есть, то
    /// есть расшифровку. А само состояние чинится там, где возникло —
    /// `.summarized` ⟺ файл и метаданные (I9), `reconcileSummarizedStage`
    /// откатывает стадию на `.saved`, и воркер дописывает саммари. Правило,
    /// которое рисовало бы здесь «Саммари пока нет», обещало бы «пока» тому,
    /// у кого работа уже кончилась, — и прятало бы дефект за формулировкой.
    func testДоведённаяВстречаБезСаммариПоказываетРасшифровкуАЧинитБэкфилл() {
        XCTAssertEqual(
            decide(hasTranscript: true, rest: .done(.complete)),
            .transcript
        )
    }
}
