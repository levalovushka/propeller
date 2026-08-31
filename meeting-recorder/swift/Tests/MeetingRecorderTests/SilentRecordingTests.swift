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

    func testНулеваяДлительностьЭтоНеЗнаюАНеНольСекунд() {
        // Ноль приходит не от записи, а от неудавшегося чтения заголовка wav:
        // именно так выглядела **каждая** подобранная с диска встреча, пока
        // `WavHeader` разбирал файл по фиксированным смещениям. На ветке
        // `.discard` `AppState.settleSilentRecording` зовёт `remove` — без
        // надгробия и без ⌘Z, — то есть двадцатиминутный созвон уходил вместе с
        // аудио. Убирать можно только за тем промахом, который измерен.
        XCTAssertEqual(
            SilentRecording.verdict(duration: 0, hasTranscript: false, hasNotes: false),
            .rest
        )
        XCTAssertEqual(
            SilentRecording.verdict(duration: -1, hasTranscript: false, hasNotes: false),
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

    // MARK: - Дефект 5: промах по кнопке отсекается до очереди

    /// 29 из 45 записей у двенадцати человек короче минуты, и все автоматические
    /// (по парку доля вдвое ниже — 28 %). Такая запись сносилась, но **только
    /// после расшифровки**: сайдкар на 981 МБ поднимался ради трёх секунд
    /// тишины, а `SilentRecording.verdict` звался уже после того, как ASR
    /// отработал вхолостую.
    func testАвтостартКорочеПорогаОтсекаетсяДоОчереди() {
        XCTAssertTrue(SilentRecording.slipsBeforeQueue(
            duration: 3, autoStarted: true, hasTranscript: false, hasNotes: false
        ))
        XCTAssertFalse(
            SilentRecording.slipsBeforeQueue(
                duration: SilentRecording.slipSeconds,
                autoStarted: true, hasTranscript: false, hasNotes: false
            ),
            "порог тот же, что и после ASR, — на границе запись живёт"
        )
    }

    /// «Человек нажал и быстро закончил» — настоящая короткая запись. Он что-то
    /// этим имел в виду, и его три секунды идут в очередь, как шли: отсекается
    /// только то, что приложение начало само по ложному детекту.
    func testРучнаяКороткаяЗаписьИдётВОчередьКакШла() {
        XCTAssertFalse(SilentRecording.slipsBeforeQueue(
            duration: 3, autoStarted: false, hasTranscript: false, hasNotes: false
        ))
    }

    /// Заметку написали руками, транскрипт остался от удачного прохода. Ни то ни
    /// другое не стирается, какой бы короткой запись ни была.
    func testЗаметкиИТранскриптНеСъедаютсяВместеСПромахом() {
        XCTAssertFalse(SilentRecording.slipsBeforeQueue(
            duration: 3, autoStarted: true, hasTranscript: false, hasNotes: true
        ))
        XCTAssertFalse(SilentRecording.slipsBeforeQueue(
            duration: 3, autoStarted: true, hasTranscript: true, hasNotes: false
        ))
    }

    /// Ноль — это «не знаю», а не «нуль секунд»: длительность приходит из
    /// индекса, и разбор заголовка wav уже один раз врал на всех записях
    /// (`JUNK` перед `fmt `). Двадцатиминутная встреча не имеет права уйти
    /// из-за неудавшегося чтения заголовка — тем более до расшифровки.
    func testНеизвестнаяДлительностьНеПоводУдалять() {
        XCTAssertFalse(SilentRecording.slipsBeforeQueue(
            duration: 0, autoStarted: true, hasTranscript: false, hasNotes: false
        ))
    }

    /// Порог у обеих дверей один: правка переносит решение раньше, а не меняет
    /// его. Разойдись они — приложение стирало бы до расшифровки то, что после
    /// расшифровки оставляло.
    func testДоОчередиИПослеASRСудятПоОдномуПорогу() {
        for seconds in stride(from: 0.5, through: 30.0, by: 0.5) {
            let before = SilentRecording.slipsBeforeQueue(
                duration: seconds, autoStarted: true, hasTranscript: false, hasNotes: false
            )
            let after = SilentRecording.verdict(
                duration: seconds, hasTranscript: false, hasNotes: false
            ) == .discard
            XCTAssertEqual(before, after, "разошлись на \(seconds)s")
        }
    }
}
