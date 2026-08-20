import XCTest
@testable import PropellerPure

/// What the model is asked, and what the person is left with. Both were
/// unreachable by tests until 2026-08-20, and both accepted two arguments they
/// discarded on the first line.
final class RecapDocumentTests: XCTestCase {

    // MARK: - The prompt

    /// A note is the one part of the input a human chose to write. When the note
    /// and the transcript disagree, the note is the anchor — so it has to arrive
    /// before the transcript and say what it is.
    func testANoteArrivesBeforeTheTranscriptAndSaysWhatItIs() {
        let out = RecapDocument.userMessage(
            title: "Синк по найму",
            transcriptMarkdown: "**Левон** · 00:03\nНачали.",
            notes: "смета к пятнице"
        )
        let notesAt = out.range(of: "смета к пятнице")
        let bodyAt = out.range(of: "Транскрипт:")
        XCTAssertNotNil(notesAt)
        XCTAssertNotNil(bodyAt)
        XCTAssertTrue(notesAt!.lowerBound < bodyAt!.lowerBound)
        XCTAssertTrue(out.contains("Заметки пользователя"))
    }

    /// An empty note is not a note. An empty section header would tell the model
    /// there were anchors and then show it none.
    func testNoNoteMeansNoNotesSection() {
        for notes in [nil, "", "   \n  "] as [String?] {
            let out = RecapDocument.userMessage(
                title: "Т", transcriptMarkdown: "текст", notes: notes
            )
            XCTAssertFalse(out.contains("Заметки пользователя"), "for \(String(describing: notes))")
        }
    }

    func testAMeetingWithoutANameSaysSoRatherThanLeavingABlank() {
        let out = RecapDocument.userMessage(title: "", transcriptMarkdown: "текст", notes: nil)
        XCTAssertTrue(out.hasPrefix("Встреча: без названия"))
    }

    /// The language is pinned in the message itself, not only in the system
    /// prompt: a model that drifts into another language produces a recap
    /// nobody in this product can read.
    func testTheAnswerIsAskedForInRussian() {
        let out = RecapDocument.userMessage(title: "Т", transcriptMarkdown: "текст", notes: nil)
        XCTAssertTrue(out.hasSuffix("Ответь строго на русском языке."))
    }

    // MARK: - The file

    func testTheSimpleRecapOpensWithTheMeetingsName() {
        let out = RecapDocument.wrapped(
            title: "Синк", recapBody: "## Итог\n\nВсё решили.", notes: nil, format: .simple
        )
        XCTAssertTrue(out.hasPrefix("# Синк — рекап\n"))
        XCTAssertTrue(out.contains("## Итог"))
    }

    func testAnUnnamedRecapStillHasAHeading() {
        let out = RecapDocument.wrapped(title: "", recapBody: "текст", notes: nil, format: .simple)
        XCTAssertTrue(out.hasPrefix("# Meeting recap\n"))
    }

    /// A quote in the title would close the YAML string early and break the file
    /// for every tool that reads the vault.
    func testAQuoteInTheTitleCannotBreakTheFrontmatter() {
        let out = RecapDocument.wrapped(
            title: #"Разбор "Мира""#, recapBody: "текст", notes: nil, format: .obsidian
        )
        XCTAssertTrue(out.contains(#"title: "Разбор 'Мира' — рекап""#))
        XCTAssertTrue(out.contains("tags: [meeting, recap]"))
    }

    /// The note is placed by `RecapNotes`, and the text stays verbatim: the
    /// model never rewrites what a person typed.
    func testTheNoteSurvivesWordForWord() {
        let out = RecapDocument.wrapped(
            title: "Т", recapBody: "## Итог\n\nВсё решили.",
            notes: "проверить смету у Иры", format: .simple
        )
        XCTAssertTrue(out.contains("проверить смету у Иры"))
    }

    // MARK: - Состав встречи (plan-people.md §6, имена из журнала окна)

    func testСоставЧитаетсяИзМетокЛенты() {
        let transcript = """
        [Левон] [00:01]
        Привет.

        [Arina Soldatenkova] [00:05]
        Привет!

        [Speaker S1] [00:12]
        (не назван)

        [Собеседник] [00:20]
        (деградация дорожек)

        [Я] [00:24]
        (владелец без имени в настройках)

        [Arina Soldatenkova] [00:30]
        Повтор не задваивается.
        """
        XCTAssertEqual(RecapDocument.participants(fromTranscript: transcript),
                       ["Левон", "Arina Soldatenkova"])
    }

    /// Расшифровка, которую читает саммари, лежит на диске в другом виде, чем
    /// та, что ходит по пайплайну. Формат берётся у самого writer'а, а не
    /// переписывается сюда руками — иначе тест разойдётся с ним молча, как это
    /// и случилось до 2026-08-20: состав был пуст на каждой живой встрече.
    func testСоставЧитаетсяИзТогоВидаЧтоЛежитНаДиске() {
        let inMemory = """
        [Левон] [00:00]
        Здоровско.

        [Aleksandra Nikandrova] [08:27]
        Привет.

        [Speaker S3] [08:28]
        Привет.

        [Я] [09:00]
        Без имени в настройках.
        """
        let onDisk = MeetingMarkdown.transcriptBody(inMemory)
        XCTAssertTrue(onDisk.contains("**Левон** · 00:00"), "формат writer'а сменился — правь оба места")
        XCTAssertEqual(RecapDocument.participants(fromTranscript: onDisk),
                       ["Левон", "Aleksandra Nikandrova"])
        XCTAssertEqual(RecapDocument.participants(fromTranscript: inMemory),
                       RecapDocument.participants(fromTranscript: onDisk))
    }

    /// Длинная встреча: минуты не капаются, `83:12` — законная метка.
    func testДлиннаяВстречаНеТеряетУчастников() {
        let onDisk = "**Вячеслав Киржаев** · 83:12\nВот и всё."
        XCTAssertEqual(RecapDocument.participants(fromTranscript: onDisk), ["Вячеслав Киржаев"])
    }

    func testСоставПопадаетВПромптОднойСтрокой() {
        let msg = RecapDocument.userMessage(
            title: "Синк", transcriptMarkdown: "[Левон] [00:01]\nПривет.",
            notes: nil, participants: ["Левон", "Kate"]
        )
        XCTAssertTrue(msg.contains("Участники: Левон, Kate."))
        // Без состава промпт остаётся прежним — плейсхолдеры не притворяются людьми.
        let bare = RecapDocument.userMessage(
            title: "Синк", transcriptMarkdown: "х", notes: nil, participants: []
        )
        XCTAssertFalse(bare.contains("Участники:"))
    }
}
