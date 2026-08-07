import XCTest
@testable import PropellerPure

/// Записи, в которых никто не говорил — `PropellerPure/SilentRecording.swift`.
///
/// Названы по тому, что видел человек: до этой развилки пустая запись вставала
/// в очередь навсегда и раз в час просила сайдкар расшифровать тишину.
final class SilentRecordingTests: XCTestCase {

    func testСлучайноНажалИТутЖеОстановилЗаписьНеОстаётся() {
        // Три секунды тишины — это промах по кнопке. Строку, которую человеку
        // придётся удалять руками, приложение заводить не должно.
        XCTAssertEqual(
            SilentRecording.verdict(duration: 3, hasTranscript: false, hasNotes: false),
            .discard
        )
    }

    func testДвадцатьСекундТишиныЭтоВстречаНаКоторойВсеМолчали() {
        // Созвон, куда никто не пришёл. Запись была, её время и название —
        // факты; удалить её значило бы стереть след того, что созвон случился.
        XCTAssertEqual(
            SilentRecording.verdict(duration: 20, hasTranscript: false, hasNotes: false),
            .rest
        )
    }

    func testНаПорогеЗаписьОстаётся() {
        // Граница названа один раз и здесь же проверена: ровно пять секунд — уже
        // не промах.
        XCTAssertEqual(
            SilentRecording.verdict(
                duration: SilentRecording.slipSeconds, hasTranscript: false, hasNotes: false
            ),
            .rest
        )
        XCTAssertEqual(
            SilentRecording.verdict(
                duration: SilentRecording.slipSeconds - 0.01, hasTranscript: false, hasNotes: false
            ),
            .discard
        )
    }

    func testЗаметкуНаписаннуюРукамиПустойОтветASRНеСтирает() {
        // Короткая запись с заметкой: человек что-то записал в неё сам, и это
        // единственное, чего пайплайн вернуть не сможет.
        XCTAssertEqual(
            SilentRecording.verdict(duration: 2, hasTranscript: false, hasNotes: true),
            .rest
        )
    }

    func testРасшифровкуОтУдачногоПроходаПустойОтветASRНеСтирает() {
        // Встречу отправили на переобработку, и на этот раз ASR вернул ноль.
        // Удалить её значило бы потерять текст, который уже был прочитан.
        XCTAssertEqual(
            SilentRecording.verdict(duration: 2, hasTranscript: true, hasNotes: false),
            .rest
        )
    }

    // MARK: - Что человек об этом читает

    func testТишинаНеЗвучитКакОтказДвижка() {
        // «Ждём ответа сервиса» на встрече, где сервис ответил за 0.7 с, — это
        // тот баг, ради которого вся развилка и появилась.
        XCTAssertEqual(MeetingRest.done(.noSpeech).disclosure, "Никто ничего не сказал")
    }

    func testПустойЗаписиБольшеНичегоНеПричитается() {
        // Терминал — единственный вид отказа, который выводит встречу из
        // очереди; строка перестаёт шиммерить, потому что работы правда нет.
        let rest = MeetingRest.of(
            stage: .recorded,
            failure: PipelineFailure(
                phase: .transcribing,
                message: MeetingRest.TerminalReason.noSpeech.logMessage,
                previous: nil,
                kind: .terminal,
                terminalReason: .noSpeech
            ),
            isWorkingOnIt: false,
            summariesEnabled: true,
            summaryModelReady: true
        )
        XCTAssertEqual(rest, .done(.noSpeech))
        XCTAssertFalse(rest.owesWork)
        XCTAssertEqual(
            SidebarRowMachine.activity(stage: .recorded, involvement: .idle, isTerminal: true),
            .rests
        )
    }
}
