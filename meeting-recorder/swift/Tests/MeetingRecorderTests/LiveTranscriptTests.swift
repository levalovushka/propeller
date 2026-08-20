import XCTest
@testable import PropellerPure

/// Живая строка во время встречи. Названия — про то, что видит человек: всё, что
/// может здесь сломаться, ломается на экране, а не в типе.
final class LiveTranscriptTests: XCTestCase {

    private func transcript(_ build: (inout LiveTranscript) -> Void) -> LiveTranscript {
        var live = LiveTranscript()
        build(&live)
        return live
    }

    // MARK: - Приём

    func testСказанноеПоявляетсяРепликойСоВременемИКаналом() {
        let live = transcript {
            $0.absorb(channel: .owner, start: 3.84, end: 4.44, text: "Итак.")
        }
        XCTAssertEqual(live.turns.count, 1)
        XCTAssertEqual(live.turns[0].text, "Итак.")
        XCTAssertEqual(live.turns[0].channel, .owner)
        XCTAssertEqual(live.turns[0].timestamp, "00:03")
        XCTAssertFalse(live.isEmpty)
    }

    func testПустойОтветНичегоНеДобавляет() {
        let live = transcript {
            $0.absorb(channel: .remote, start: 5, end: 5.6, text: "   ")
        }
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(live.turns.isEmpty)
    }

    // MARK: - Склейка в реплики

    func testПодрядИдущиеКускиОдногоКаналаЭтоОднаРеплика() {
        let live = transcript {
            $0.absorb(channel: .owner, start: 3.8, end: 4.4, text: "Итак.")
            $0.absorb(channel: .owner, start: 5.4, end: 6.0, text: "ещё один")
            $0.absorb(channel: .owner, start: 6.1, end: 6.6, text: "тест.")
        }
        XCTAssertEqual(live.turns.count, 1)
        XCTAssertEqual(live.turns[0].text, "Итак. ещё один тест.")
        XCTAssertEqual(live.turns[0].timestamp, "00:03")
    }

    func testСменаКаналаНачинаетНовуюРеплику() {
        let live = transcript {
            $0.absorb(channel: .owner, start: 1, end: 2, text: "Привет.")
            $0.absorb(channel: .remote, start: 2.2, end: 3, text: "Привет.")
        }
        XCTAssertEqual(live.turns.map(\.channel), [.owner, .remote])
    }

    func testДолгаяПаузаРазрываетРепликуТогоЖеКанала() {
        let live = transcript {
            $0.absorb(channel: .owner, start: 1, end: 2, text: "Начали.")
            $0.absorb(channel: .owner, start: 30, end: 31, text: "Продолжаем.")
        }
        XCTAssertEqual(live.turns.count, 2)
    }

    func testОборванноеСловоСклеиваетсяБезПробела() {
        let live = transcript {
            $0.absorb(channel: .owner, start: 7.2, end: 7.7, text: "как рабо-")
            $0.absorb(channel: .owner, start: 7.8, end: 8.2, text: "тает")
        }
        XCTAssertEqual(live.turns[0].text, "как рабо-тает")
    }

    // MARK: - Порядок

    func testРепликиИдутПоВремениСказанного_аНеПоВремениОтвета() {
        // Системная сессия ответила раньше про более поздний момент.
        let live = transcript {
            $0.absorb(channel: .remote, start: 12, end: 13, text: "Второй.")
            $0.absorb(channel: .owner, start: 4, end: 5, text: "Первый.")
        }
        XCTAssertEqual(live.turns.map(\.text), ["Первый.", "Второй."])
    }

    func testПриОдинаковомВремениПорядокУстойчив() {
        let live = transcript {
            $0.absorb(channel: .owner, start: 7, end: 8, text: "Раз.")
            $0.absorb(channel: .remote, start: 7, end: 8, text: "Два.")
        }
        XCTAssertEqual(live.turns.map(\.text), ["Раз.", "Два."])
        XCTAssertEqual(live.turns.map(\.id), live.turns.map(\.id))
    }

    /// Имя реплики — то, за что держится печатная машинка: пока к реплике
    /// дописывают, она остаётся той же строкой и допечатывает хвост.
    func testИмяРепликиНеМеняетсяПокаКНейДописывают() {
        var live = LiveTranscript()
        live.absorb(channel: .owner, start: 1, end: 2, text: "Раз.")
        let id = live.turns[0].id
        live.absorb(channel: .owner, start: 2.2, end: 2.8, text: "два.")
        XCTAssertEqual(live.turns[0].id, id)
        XCTAssertEqual(live.turns[0].text, "Раз. два.")
    }

    // MARK: - Сброс

    func testНоваяЗаписьНачинаетСПустого() {
        var live = LiveTranscript()
        live.absorb(channel: .owner, start: 1, end: 2, text: "Прошлая встреча.")
        live.reset()
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(live.turns.isEmpty)
    }

    // MARK: - Мусор от движка

    func testОтрицательноеИНечисловоеВремяНеЛомаютПорядок() {
        let live = transcript {
            $0.absorb(channel: .owner, start: .nan, end: .infinity, text: "Раз.")
            $0.absorb(channel: .remote, start: -5, end: -1, text: "Два.")
        }
        XCTAssertEqual(live.turns.map(\.startSeconds), [0, 0])
        XCTAssertEqual(live.turns.map(\.timestamp), ["00:00", "00:00"])
    }

    // MARK: - Имена из журнала окна (2026-08-20)

    func testИмяДаётсяПриРожденииИНеПересматривается() {
        var t = LiveTranscript()
        t.absorb(channel: .remote, start: 10, end: 12, text: "Начало реплики,", name: "Kate")
        // Продолжение приходит уже с другим мнением журнала — подпись на
        // экране не переписывается.
        t.absorb(channel: .remote, start: 12.5, end: 14, text: "и её хвост.", name: nil)
        let turns = t.turns
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].name, "Kate")
        XCTAssertTrue(turns[0].text.contains("хвост"))
    }

    func testБезымяннаяРепликаОстаётсяКакСегодня() {
        var t = LiveTranscript()
        t.absorb(channel: .remote, start: 10, end: 12, text: "Реплика без журнала.")
        XCTAssertNil(t.turns[0].name)
    }

    func testЧерновикНаДискНесётИмяИзЖурнала() {
        var t = LiveTranscript()
        t.absorb(channel: .remote, start: 10, end: 12, text: "Именованная.", name: "Kate")
        t.absorb(channel: .remote, start: 40, end: 42, text: "Безымянная.")
        let persisted = t.persistedSegments(ownerName: "Левон")
        XCTAssertEqual(persisted[0].speaker, "Kate")
        XCTAssertEqual(persisted[1].speaker, SourceAwareSpeaker.defaultRemoteName)
    }
}
