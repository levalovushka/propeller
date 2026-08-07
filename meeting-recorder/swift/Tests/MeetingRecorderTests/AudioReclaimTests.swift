import XCTest
@testable import PropellerPure

/// У какой встречи «Очистить» забирает аудио — `PropellerPure/AudioReclaim.swift`.
///
/// Названы по тому, что человек увидел бы, если правило ошибётся: встреча,
/// которую больше никогда не расшифруют, и встреча, которая просто исчезла из
/// списка. Оба исхода необратимы, поэтому у кнопки «удалить всё аудио» правило
/// проверяется, а не подразумевается.
final class AudioReclaimTests: XCTestCase {

    // MARK: - Кого нельзя трогать

    func testУИдущейЗаписиАудиоНеЗабирают() {
        // Файл прямо сейчас пишется. `nextPhase` у `.recording` — nil, то есть
        // «воркеру ничего не причитается», и без отдельной проверки эта встреча
        // попала бы в «аудио больше не нужно» первой из всех.
        XCTAssertFalse(
            AudioReclaim.isExpendable(stage: .recording, hasTranscript: false)
        )
    }

    func testЗаписьКоторуюЕщёНеРасшифровалиОстаётсяСАудио() {
        // Аудио — вход ASR. Забрать его здесь значит не освободить место, а
        // отменить встречу: `owedPhase` вернёт nil, и воркер пройдёт мимо
        // навсегда.
        XCTAssertFalse(
            AudioReclaim.isExpendable(stage: .recorded, hasTranscript: false)
        )
    }

    func testПередДиаризациейАудиоЕщёНужноХотяТекстУжеЕсть() {
        // Самая коварная ступень: расшифровка уже есть, и по тексту встреча
        // выглядит готовой — а звук ещё читает диаризация. Порог «есть текст ⇒
        // можно» оставил бы её без спикеров навсегда.
        XCTAssertFalse(
            AudioReclaim.isExpendable(stage: .transcribedRaw, hasTranscript: true)
        )
    }

    func testВстречаБезТекстаНеТеряетАудиоДажеНаПоследнейСтупени() {
        // Список показывает встречу, если у неё есть текст или файл. Нет ни
        // того, ни другого — и она исчезает из рельса, хотя в индексе лежит.
        XCTAssertFalse(
            AudioReclaim.isExpendable(stage: .summarized, hasTranscript: false)
        )
    }

    // MARK: - У кого аудио действительно лишнее

    func testУДоделаннойВстречиАудиоЛишнее() {
        XCTAssertTrue(
            AudioReclaim.isExpendable(stage: .summarized, hasTranscript: true)
        )
    }

    func testПослеДиаризацииАудиоБольшеНиктоНеЧитает() {
        // Остались `.saving` и `.summarizing` — обе работают с текстом.
        for stage in [RecordingStage.transcribed, .saved] {
            XCTAssertTrue(
                AudioReclaim.isExpendable(stage: stage, hasTranscript: true),
                "\(stage.rawValue) уже не нуждается в звуке"
            )
        }
    }

    // MARK: - Правило целиком

    func testНиОднаВстречаНеОстаётсяБезРаботыИБезСтроки() {
        // Свойство, которое и есть смысл файла: что бы ни выбрала чистка, после
        // неё у встречи либо есть текст (значит, её видно в списке), либо ей
        // ничего не причитается из того, что читает звук.
        for stage in RecordingStage.allCases {
            for hasTranscript in [true, false] {
                guard AudioReclaim.isExpendable(
                    stage: stage, hasTranscript: hasTranscript
                ) else { continue }
                XCTAssertTrue(hasTranscript, "\(stage.rawValue) исчезнет из списка")
                XCTAssertNotEqual(
                    stage.nextPhase?.needsAudio, true,
                    "\(stage.rawValue) встанет без входа"
                )
            }
        }
    }
}
