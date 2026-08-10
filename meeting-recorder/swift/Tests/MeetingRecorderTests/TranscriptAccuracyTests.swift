import XCTest
@testable import PropellerPure

/// Линейка, которой мы будем судить экономию.
///
/// Каждый тест здесь — про то, чем эта линейка обязана быть чувствительна к
/// порче продукта: пропала речь, слова уехали к другому человеку, текст
/// распался. Если линейка это не видит, то она разрешит «ускорение», которое
/// на самом деле выключило распознавание.
final class TranscriptAccuracyTests: XCTestCase {

    private let reference = "Привет. Давайте быстро обсудим план на спринт."

    // MARK: - Нормализация

    func testПунктуацияИРегистрНеСчитаютсяОшибкой() {
        let r = TranscriptAccuracy.compare(
            hypothesis: "привет давайте быстро обсудим план на спринт",
            reference: reference
        )
        XCTAssertEqual(r.wer, 0)
        XCTAssertEqual(r.coverage, 1)
    }

    func testЁИЕОдноИТоЖеСлово() {
        // Движок пишет «ещё», эталон — «еще»; человек разницы не увидит, и
        // метрика не должна.
        let r = TranscriptAccuracy.compare(hypothesis: "ещё раз", reference: "еще раз")
        XCTAssertEqual(r.wer, 0)
    }

    func testОборванноеСловоОстаётсяОднимСловом() {
        // Движок помечает обрыв дефисом («рабо-таем»): склейка в LiveTranscript
        // даёт одно слово, и разбивать его на два метрика не имеет права.
        XCTAssertEqual(TranscriptAccuracy.words(in: "по-моему так"), ["по-моему", "так"])
        XCTAssertEqual(TranscriptAccuracy.words(in: "слово — тире"), ["слово", "тире"])
    }

    // MARK: - Чем ловится порча

    func testПропавшаяРечьВидна() {
        // Ровно та ловушка, ради которой существует coverage: гейт замолчал на
        // трёх словах из семи.
        let r = TranscriptAccuracy.compare(
            hypothesis: "привет давайте быстро обсудим",
            reference: reference
        )
        XCTAssertEqual(r.deletions, 3)
        XCTAssertEqual(r.coverage, 4.0 / 7.0, accuracy: 0.001)
        XCTAssertEqual(r.wer, 3.0 / 7.0, accuracy: 0.001)
    }

    func testВыброшенныйХвостНеПрячетсяЗаХорошимWER() {
        // Половину встречи не распознали. WER = 0.5, но главное — coverage
        // говорит прямо: половины слов нет.
        let r = TranscriptAccuracy.compare(
            hypothesis: "привет давайте быстро обсудим",
            reference: "привет давайте быстро обсудим план на спринт нужно"
        )
        XCTAssertEqual(r.coverage, 4.0 / 8.0, accuracy: 0.001)
        XCTAssertEqual(r.insertions, 0)
        XCTAssertEqual(r.substitutions, 0)
    }

    func testЛишнийТекстСчитаетсяВставкой() {
        let r = TranscriptAccuracy.compare(
            hypothesis: "привет привет давайте быстро обсудим план на спринт",
            reference: reference
        )
        XCTAssertEqual(r.insertions, 1)
        XCTAssertEqual(r.coverage, 1, "ни одно слово эталона не потерялось")
    }

    func testПодменаСловаЭтоОднаОшибкаАНеДве() {
        let r = TranscriptAccuracy.compare(
            hypothesis: "привет давайте быстро обсудим план на спирт",
            reference: reference
        )
        XCTAssertEqual(r.substitutions, 1)
        XCTAssertEqual(r.deletions, 0)
        XCTAssertEqual(r.insertions, 0)
        XCTAssertEqual(r.coverage, 1, "слово доехало, пусть и кривым")
    }

    func testПустойТекстПротивЭталонаТеряетВсё() {
        let r = TranscriptAccuracy.compare(hypothesis: "", reference: reference)
        XCTAssertEqual(r.coverage, 0)
        XCTAssertEqual(r.wer, 1)
        XCTAssertEqual(r.matches, 0)
    }

    // MARK: - Кому приписаны слова

    func testСловаПодПравильнойДорожкойСчитаютсяВерными() {
        var live = LiveTranscript()
        live.absorb(channel: .owner, start: 0, end: 2, text: "привет давайте")
        live.absorb(channel: .remote, start: 3, end: 5, text: "хорошо я возьму")

        let r = TranscriptAccuracy.compare(
            hypothesis: TranscriptAccuracy.words(in: live),
            reference: [
                .init(text: "привет", channel: .owner),
                .init(text: "давайте", channel: .owner),
                .init(text: "хорошо", channel: .remote),
                .init(text: "я", channel: .remote),
                .init(text: "возьму", channel: .remote),
            ]
        )
        XCTAssertEqual(r.wer, 0)
        XCTAssertEqual(r.attributionAccuracy, 1)
    }

    func testЧужаяРечьПодИменемВладельцаВиднаОтдельноОтWER() {
        // Эхо из колонки: текст распознан дословно верно, но подписан не тем.
        // WER этого не заметит — attribution обязан.
        var live = LiveTranscript()
        live.absorb(channel: .owner, start: 0, end: 2, text: "хорошо я возьму")

        let r = TranscriptAccuracy.compare(
            hypothesis: TranscriptAccuracy.words(in: live),
            reference: [
                .init(text: "хорошо", channel: .remote),
                .init(text: "я", channel: .remote),
                .init(text: "возьму", channel: .remote),
            ]
        )
        XCTAssertEqual(r.wer, 0, "слова те самые")
        XCTAssertEqual(r.attributionAccuracy, 0, "но человек не тот")
    }

    func testБезДорожекАтрибуцияНеСчитаетсяВовсе() {
        let r = TranscriptAccuracy.compare(hypothesis: "привет", reference: "привет")
        XCTAssertNil(r.attributionAccuracy)
    }

    // MARK: - Устойчивость

    func testОдинаковыйТекстДаётНольНезависимоОтДлины() {
        let long = Array(repeating: "слово", count: 500).joined(separator: " ")
        let r = TranscriptAccuracy.compare(hypothesis: long, reference: long)
        XCTAssertEqual(r.wer, 0)
        XCTAssertEqual(r.matches, 500)
    }

    func testПустойЭталонНеДелитНаНоль() {
        XCTAssertEqual(TranscriptAccuracy.compare(hypothesis: "", reference: "").wer, 0)
        XCTAssertEqual(TranscriptAccuracy.compare(hypothesis: "текст", reference: "").wer, 1)
    }
}
