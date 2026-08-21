import XCTest
import PropellerPure

/// # У заметки появилось время, и ничего от этого не изменилось
///
/// Время заметки жило строкой `[12:34] ` в начале её же текста — читать удобно,
/// поставить заметку рядом с репликой невозможно: у реплики время это число.
/// Теперь это поле. Файл на диске, промпт модели и поиск читают ту же строку,
/// что и раньше, и вот этот файл — про то, что она не поехала.
final class NoteTimecodeTests: XCTestCase {

    // MARK: - Контракт на диске

    /// То, что уходит в «Заметки» файла и в промпт, выглядит ровно как прежде.
    func testTheFileStillSeesTheStampInFrontOfTheNote() {
        let note = MeetingNoteRecord(id: "a", text: "решили не тянуть", offsetSeconds: 754)
        XCTAssertEqual(MeetingNotes.blob(from: [note]), "[12:34] решили не тянуть")
    }

    /// Час и больше — та же форма, что у таймера записи. Проверяется через то,
    /// что уходит на диск: формой числа владеет `Timecode` и её тесты, а здесь
    /// вопрос про заметку — дошла ли эта форма до файла.
    func testAnHourInIsWrittenTheWayTheTimerWritesIt() {
        let note = MeetingNoteRecord(id: "a", text: "и через час", offsetSeconds: 3723)
        XCTAssertEqual(MeetingNotes.blob(from: [note]), "[1:02:03] и через час")
    }

    /// Заметка, написанная после встречи, никакой секунде не принадлежит — и
    /// штампа не получает. Выдуманная секунда хуже отсутствующей.
    func testANoteWrittenAfterTheMeetingCarriesNoStamp() {
        let note = MeetingNoteRecord(id: "a", text: "дописал вечером")
        XCTAssertEqual(MeetingNotes.blob(from: [note]), "дописал вечером")
        XCTAssertNil(MeetingNotes.placed(note).seconds)
    }

    /// Старая заметка несёт штамп внутри текста. Второго она не получает —
    /// иначе один и тот же файл, прочитанный новой сборкой, обрастает `[12:34]
    /// [12:34]` на каждом сохранении.
    func testANoteThatAlreadyCarriesItsStampIsNotStampedTwice() {
        let legacy = MeetingNoteRecord(id: "a", text: "[12:34] из чёлки", offsetSeconds: 754)
        XCTAssertEqual(MeetingNotes.blob(from: [legacy]), "[12:34] из чёлки")
    }

    // MARK: - Чтение старого архива

    /// Время старых заметок читается из текста, а сам текст на диске не
    /// переписывается: чужой архив правят по просьбе, а не под новое поле.
    func testTheTimeOfAnOldNoteIsReadOutOfItsText() {
        let legacy = MeetingNoteRecord(id: "a", text: "[07:20] важное")
        let placed = MeetingNotes.placed(legacy)
        XCTAssertEqual(placed.seconds, 440)
        XCTAssertEqual(placed.text, "важное")
        XCTAssertEqual(legacy.text, "[07:20] важное", "Запись не тронута.")
    }

    func testAnHourLongStampIsReadToo() {
        XCTAssertEqual(MeetingNotes.placed(.init(id: "a", text: "[1:02:03] х")).seconds, 3723)
    }

    /// Квадратная скобка в начале — ещё не таймкод. Заметка «[TODO] позвонить»
    /// не должна уехать в нулевую секунду и потерять начало.
    func testSomethingThatIsNotATimecodeIsLeftAlone() {
        for text in ["[TODO] позвонить", "[] пусто", "[12] один кусок", "[a:b] буквы"] {
            let placed = MeetingNotes.placed(.init(id: "a", text: text))
            XCTAssertNil(placed.seconds, text)
            XCTAssertEqual(placed.text, text, text)
        }
    }

    /// Поле сильнее строки: если заметка знает своё время сама, читают его.
    func testTheFieldWinsOverTheTextWhenBothAreThere() {
        let note = MeetingNoteRecord(id: "a", text: "[00:05] х", offsetSeconds: 754)
        XCTAssertEqual(MeetingNotes.placed(note).seconds, 754)
        XCTAssertEqual(MeetingNotes.placed(note).text, "х")
    }

    // MARK: - Совместимость файла индекса

    /// Архив, записанный сборкой без этого поля, открывается как ни в чём не
    /// бывало — поле необязательное и в модели, и в JSON.
    func testAnArchiveWrittenBeforeThisFieldStillDecodes() throws {
        let old = """
        {"id":"n1","text":"старая","createdAt":760000000}
        """.data(using: .utf8)!
        let note = try JSONDecoder().decode(MeetingNoteRecord.self, from: old)
        XCTAssertEqual(note.text, "старая")
        XCTAssertNil(note.offsetSeconds)
    }
}
