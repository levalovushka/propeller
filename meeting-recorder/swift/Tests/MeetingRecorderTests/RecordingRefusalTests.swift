import XCTest
@testable import PropellerPure

/// «Просили записать, а записи нет» — `PropellerPure/RecordingRefusal.swift`.
///
/// Названо по тому, что человек видел: он нажал «Новая запись», и не произошло
/// ничего. `beginRecording` глотал отказ захвата целиком — ни строки в рельсе,
/// ни лога, ни возвращённого воркера, — и встреча, которая шла прямо сейчас, не
/// записывалась молча.
final class RecordingRefusalTests: XCTestCase {

    func testКаждыйОтказГоворитЗаСебяВРельсе() {
        // Ни одного случая, который человек узнаёт только из логов.
        for refusal in RecordingRefusal.allCases {
            XCTAssertFalse(refusal.railTitle.isEmpty, "\(refusal)")
            XCTAssertFalse(refusal.railSymbol.isEmpty, "\(refusal)")
        }
    }

    func testОтказыНеПутаютсяДругСДругом() {
        // Одна строка на два случая означала бы «чините не то»: микрофон
        // выдают в системных настройках, захват — повторной попыткой.
        let titles = Set(RecordingRefusal.allCases.map(\.railTitle))
        XCTAssertEqual(titles.count, RecordingRefusal.allCases.count)
    }

    func testМикрофонВедётВРазрешениеАНеВПовторнуюПопытку() {
        // Нажимать «Новая запись» второй раз бессмысленно, пока разрешения нет.
        XCTAssertFalse(RecordingRefusal.microphone.retryStartsRecording)
        XCTAssertEqual(RecordingRefusal.microphone.railTitle, "Нет доступа к\u{00A0}микрофону")
    }

    func testУпавшийЗахватПробуютСнова() {
        // Устройство вернулось, вход освободился — вторая попытка бесплатна.
        XCTAssertTrue(RecordingRefusal.captureFailed.retryStartsRecording)
    }

    func testПослеУпавшегоЗахватаВоркераНадоВернуть() {
        // `pausePipeline()` стоит внутри `beginRecording`, до `try`. Ветка
        // отказа кика назад не делала, и архив стоял до следующего события —
        // молча, потому что о самом отказе тоже никто не говорил.
        XCTAssertTrue(RecordingRefusal.captureFailed.leavesPipelinePaused)
        // Микрофонная проверка идёт раньше `beginRecording`, воркера там никто
        // не снимал: лишний кик разбудил бы догон посреди звонка.
        XCTAssertFalse(RecordingRefusal.microphone.leavesPipelinePaused)
    }
}
