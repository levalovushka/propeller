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

    // MARK: - «Удалить аудио» рукой

    /// Пункт меню встречи спрашивал только «есть ли файл» — и у
    /// нерасшифрованной встречи был активен. Нажатие уносило её из списка
    /// навсегда: текста нет, записи нет, файла больше нет, значит
    /// `hasSomethingToShow` ложно во всех трёх ветках, строка уходит из рельса,
    /// а из индекса встреча не уходит. Двери назад нет ни одной.
    func testУНерасшифрованнойВстречиПунктНеактивен() {
        XCTAssertFalse(
            AudioReclaim.isManuallyDeletable(
                stage: .recorded, hasTranscript: false, audioExists: true
            )
        )
    }

    /// Та же коварная ступень, что и у чистки: текст есть, а звук ещё читает
    /// диаризация.
    func testПередДиаризациейПунктНеактивенДажеСТекстом() {
        XCTAssertFalse(
            AudioReclaim.isManuallyDeletable(
                stage: .transcribedRaw, hasTranscript: true, audioExists: true
            )
        )
    }

    /// Идущая запись пишет ровно в этот файл.
    func testУИдущейЗаписиПунктНеактивен() {
        XCTAssertFalse(
            AudioReclaim.isManuallyDeletable(
                stage: .recording, hasTranscript: false, audioExists: true
            )
        )
    }

    /// Удалять нечего — пункту нечего делать. Это единственная проверка,
    /// которая тут была, и одна она пропускала всё остальное.
    func testБезФайлаПунктНеактивен() {
        XCTAssertFalse(
            AudioReclaim.isManuallyDeletable(
                stage: .summarized, hasTranscript: true, audioExists: false
            )
        )
    }

    /// И единственный случай, когда пункт работает.
    func testУДоделаннойВстречиСФайломПунктАктивен() {
        XCTAssertTrue(
            AudioReclaim.isManuallyDeletable(
                stage: .summarized, hasTranscript: true, audioExists: true
            )
        )
    }

    /// Рука и автоматика отвечают одинаково: расхождение между ними и было
    /// дефектом. Разница ровно одна — руке нужен ещё и файл.
    func testРукаНеРасходитсяСАвтоматикой() {
        for stage in RecordingStage.allCases {
            for hasTranscript in [true, false] {
                XCTAssertEqual(
                    AudioReclaim.isManuallyDeletable(
                        stage: stage, hasTranscript: hasTranscript, audioExists: true
                    ),
                    AudioReclaim.isExpendable(stage: stage, hasTranscript: hasTranscript),
                    "\(stage.rawValue), текст: \(hasTranscript)"
                )
            }
        }
    }
}
