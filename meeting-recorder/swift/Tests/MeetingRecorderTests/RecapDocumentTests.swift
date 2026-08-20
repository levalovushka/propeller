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
}
