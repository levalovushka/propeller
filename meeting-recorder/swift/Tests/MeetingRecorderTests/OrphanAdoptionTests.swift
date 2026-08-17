import XCTest
@testable import PropellerPure

/// Кого приложение подбирает с диска, а кого нет — `PropellerPure/OrphanAdoption.swift`.
///
/// Названы по тому, что видел человек: до надгробий удалённая встреча
/// возвращалась в список без названия, и удалять её приходилось второй раз.
final class OrphanAdoptionTests: XCTestCase {

    func testПотеряннаяЗаписьВозвращаетсяВСписок() {
        // Файл на диске есть, строки в индексе нет и никто её не удалял —
        // значит мы её потеряли, и человек должен увидеть встречу.
        XCTAssertEqual(
            OrphanAdoption.adoptable(
                fileIDs: ["20260809_143856"], knownIDs: [], tombstoned: []
            ),
            ["20260809_143856"]
        )
    }

    func testУдалённаяВстречаНеВоскресает() {
        // Тот же файл, но удаление было. Вернуть её значит заставить человека
        // удалять дважды — и второй раз уже безымянную.
        XCTAssertTrue(
            OrphanAdoption.adoptable(
                fileIDs: ["20260809_143856"],
                knownIDs: [],
                tombstoned: ["20260809_143856"]
            ).isEmpty
        )
    }

    func testУжеИзвестнуюЗаписьНеЗаводятВторойРаз() {
        XCTAssertTrue(
            OrphanAdoption.adoptable(
                fileIDs: ["a"], knownIDs: ["a"], tombstoned: []
            ).isEmpty
        )
    }

    func testПослеОтменыУдаленияЗаписьОстаётсяЖивой() {
        // ⌘Z вернул встречу в индекс. Даже если камень почему-то остался,
        // спор решается в пользу индекса — и подбирать тут нечего, она на месте.
        XCTAssertTrue(
            OrphanAdoption.adoptable(
                fileIDs: ["a"], knownIDs: ["a"], tombstoned: ["a"]
            ).isEmpty
        )
    }

    // Когда камень уходит и когда обязан остаться — в `MeetingErasureTests`:
    // теперь он сторожит все следы встречи, а не только её wav, и проверяется на
    // настоящем каталоге, а не на списке имён.

    // MARK: - Неудавшийся старт

    func testЗаписьБезЕдиногоБайтаНеОстаётсяВСписке() {
        // Захват не открылся. В рельсе это была вечная строка «Идёт запись» с
        // живой точкой, переживающая перезапуск.
        XCTAssertTrue(
            RecordingRecovery.isFailedStart(
                stage: .recording, hasAnyAudio: false,
                hasTranscript: false, hasNotes: false
            )
        )
    }

    func testНачатуюЗаписьСАудиоНеВыбрасывают() {
        XCTAssertFalse(
            RecordingRecovery.isFailedStart(
                stage: .recording, hasAnyAudio: true,
                hasTranscript: false, hasNotes: false
            )
        )
    }

    func testЗаметкуНаписаннуюВоВремяЗаписиНеТеряют() {
        // Человек успел записать мысль до того, как захват сорвался. Это
        // единственное, чего вернуть неоткуда.
        XCTAssertFalse(
            RecordingRecovery.isFailedStart(
                stage: .recording, hasAnyAudio: false,
                hasTranscript: false, hasNotes: true
            )
        )
    }

    func testДоведённыеСтадииЭтоПравилоНеТрогает() {
        for stage in RecordingStage.allCases where stage != .recording {
            XCTAssertFalse(
                RecordingRecovery.isFailedStart(
                    stage: stage, hasAnyAudio: false,
                    hasTranscript: false, hasNotes: false
                ),
                "\(stage)"
            )
        }
    }
}
