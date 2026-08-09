import XCTest
@testable import PropellerPure

/// Живой текст, пережидающий перезапуск, — `LiveTranscript.persistedSegments`.
///
/// Названы по тому, что человек терял до этого: встречу, про которую после
/// перезапуска не известно ни слова, хотя разговор шёл час.
final class LiveTranscriptPersistenceTests: XCTestCase {

    private func live(_ pieces: [(LiveTranscript.Channel, Double, Double, String)]) -> LiveTranscript {
        var t = LiveTranscript()
        for (channel, start, end, text) in pieces {
            t.absorb(channel: channel, start: start, end: end, text: text)
        }
        return t
    }

    func testЗакрылНоутбукПослеЗвонкаТекстОсталсяНаМесте() {
        let saved = live([
            (.owner, 0, 2, "Давайте начнём"),
            (.remote, 3, 5, "Да, я готов"),
        ]).persistedSegments(ownerName: "Левон")

        XCTAssertEqual(saved.map(\.text), ["Давайте начнём", "Да, я готов"])
        XCTAssertEqual(saved.map(\.startTime), [0, 3])
    }

    /// Имена — по дорожке, как их поставит финальный проход. Диаризации на
    /// живом тексте нет и не будет, но человек не должен увидеть, как реплики
    /// переименовывают говорящих в момент замены черновика настоящим текстом.
    func testГоворящихЗовутТакЖеКакИхНазовётНастоящаяРасшифровка() {
        let saved = live([
            (.owner, 0, 1, "Раз"),
            (.remote, 2, 3, "Два"),
        ]).persistedSegments(ownerName: "Левон")

        XCTAssertEqual(saved[0].speaker, "Левон")
        XCTAssertEqual(
            saved[1].speaker,
            SourceAwareSpeaker.stemsOnly(source: .system, ownerName: "Левон")
        )
    }

    /// Имени нет — подставляется то же запасное, что и везде, а не пустая
    /// строка: реплика без говорящего читается как сломанная вёрстка.
    func testБезИмениВладельцаРепликаВсёРавноПодписана() {
        let saved = live([(.owner, 0, 1, "Раз")]).persistedSegments(ownerName: "")
        XCTAssertFalse(saved[0].speaker.isEmpty)
    }

    /// Реплика, а не кусок: склейка уже случилась в живом слое, и повторять её
    /// при чтении незачем — иначе одна встреча делилась бы на реплики
    /// по-разному до и после перезапуска.
    func testПодрядИдущиеКускиОдногоГолосаОстаютсяОднойРепликой() {
        let saved = live([
            (.owner, 0, 1, "Давайте"),
            (.owner, 1, 2, "начнём"),
        ]).persistedSegments(ownerName: "Левон")

        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].text, "Давайте начнём")
    }

    func testПустойВстречеСохранятьНечего() {
        XCTAssertTrue(LiveTranscript().persistedSegments(ownerName: "Левон").isEmpty)
    }

    /// Формат тот же, которым живёт готовая расшифровка, — значит и рисуется
    /// тем же кодом. Своего формата у черновика нет намеренно: два способа
    /// нарисовать одно и то же разъезжаются.
    func testЧерновикЧитаетсяТемЖеКодомЧтоИГотоваяРасшифровка() {
        let saved = live([
            (.owner, 0, 2, "Давайте начнём"),
            (.remote, 30, 32, "Да, я готов"),
        ]).persistedSegments(ownerName: "Левон")

        let turns = TranscriptPresentation.turns(from: saved)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speaker, "Левон")
        XCTAssertEqual(turns[1].timestamp, TranscriptPresentation.formatTimestamp(30))
    }
}
