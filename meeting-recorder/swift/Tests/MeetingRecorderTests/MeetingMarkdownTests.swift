import XCTest
@testable import PropellerPure

/// The file a person keeps. Verified against three real saved meetings at the
/// moment this code moved out of the executable target — byte for byte — and
/// pinned here by shape so the next change has to mean it.
final class MeetingMarkdownTests: XCTestCase {

    private let transcript = """
    [Левон] [00:03]
    Начали.

    [Speaker S1] [01:12]
    Продолжаю мысль
    на двух строках.

    [Мария] [1:30:20]
    И через полтора часа.
    """

    // MARK: - Simple

    func testTheSimpleFileSaysWhenWhoAndHowLong() {
        let out = MeetingMarkdown.simple(
            title: "Синк по найму",
            transcript: transcript,
            duration: 911,
            speakers: ["Левон", "Мария"],
            notes: nil,
            today: "2026-08-20"
        )
        XCTAssertEqual(out.components(separatedBy: "\n").prefix(6).joined(separator: "\n"), """
        # Синк по найму

        **Date:** 2026-08-20
        **Duration:** 15 min
        **Participants:** Левон, Мария

        """)
    }

    /// A meeting nobody named still gets a heading — an empty `# ` would leave
    /// the file looking corrupt in every reader.
    func testAMeetingWithoutATitleStillHasAHeading() {
        let out = MeetingMarkdown.simple(
            title: "", transcript: "", duration: 0, speakers: [], notes: nil, today: "2026-08-20"
        )
        XCTAssertTrue(out.hasPrefix("# Meeting\n"))
        XCTAssertFalse(out.contains("**Duration:**"))
        XCTAssertFalse(out.contains("**Participants:**"))
    }

    func testNotesComeBeforeTheBodyOrNotAtAll() {
        let withNotes = MeetingMarkdown.simple(
            title: "Т", transcript: transcript, duration: 0,
            speakers: [], notes: "проверить смету", today: "2026-08-20"
        )
        let notesAt = withNotes.range(of: "## Notes")
        let bodyAt = withNotes.range(of: "## Transcript")
        XCTAssertNotNil(notesAt)
        XCTAssertNotNil(bodyAt)
        XCTAssertTrue(notesAt!.lowerBound < bodyAt!.lowerBound)

        let without = MeetingMarkdown.simple(
            title: "Т", transcript: transcript, duration: 0,
            speakers: [], notes: "", today: "2026-08-20"
        )
        XCTAssertFalse(without.contains("## Notes"))
    }

    // MARK: - The body

    func testEachRemarkBecomesANameADotAndATime() {
        XCTAssertEqual(
            MeetingMarkdown.transcriptBody("[Левон] [00:03]\nНачали."),
            "**Левон** · 00:03\nНачали."
        )
    }

    /// The stamp past the first hour is the one the two old patterns disagreed
    /// about. In the file it has to survive as a name and a time, not as text.
    func testTheHourMarkIsStillAName() {
        let out = MeetingMarkdown.transcriptBody("[Мария] [1:30:20]\nИ через полтора часа.")
        XCTAssertEqual(out, "**Мария** · 1:30:20\nИ через полтора часа.")
    }

    /// An unrecognised block is somebody's content. Dropping it to keep the
    /// format tidy would delete part of the meeting.
    func testALineThatIsNotARemarkKeepsItsWords() {
        XCTAssertEqual(MeetingMarkdown.transcriptBody("просто строка без метки"), "просто строка без метки")
    }

    func testARemarkKeepsItsSecondLine() {
        let out = MeetingMarkdown.transcriptBody("[Speaker S1] [01:12]\nПродолжаю мысль\nна двух строках.")
        XCTAssertEqual(out, "**Speaker S1** · 01:12\nПродолжаю мысль\nна двух строках.")
    }

    func testNothingSaidRendersAsNothingAndNotAStrayNewline() {
        XCTAssertEqual(MeetingMarkdown.transcriptBody(""), "")
        XCTAssertEqual(MeetingMarkdown.transcriptBody("\n\n\n"), "")
    }

    // MARK: - The shape the readers rely on

    /// Три читателя дискового вида берут форму у writer'а. Этот тест — единственное
    /// место, где сходится «как пишем» с «как читаем»: расхождение между ними уже
    /// один раз выдало промпту пустой ростер, и падать оно должно здесь, а не там.
    func testWhatTheWriterEmitsIsWhatTheReadersMatch() throws {
        let head = MeetingMarkdown.diskHead(speaker: "Левон", timecode: "1:30:20")
        XCTAssertEqual(head, "**Левон** · 1:30:20")

        let anchored = try NSRegularExpression(pattern: MeetingMarkdown.diskHeadPattern)
        let whole = NSRange(head.startIndex..., in: head)
        let match = anchored.firstMatch(in: head, range: whole)
        XCTAssertNotNil(match, "голова, которую пишет writer, не читается его же выражением")
        if let match, let name = Range(match.range(at: 1), in: head),
           let stamp = Range(match.range(at: 2), in: head) {
            XCTAssertEqual(String(head[name]), "Левон")
            XCTAssertEqual(String(head[stamp]), "1:30:20")
        }

        // И то же самое как граница нарезки: две реплики — две границы.
        let two = MeetingMarkdown.transcriptBody("[Левон] [00:03]\nРаз.\n\n[Мария] [00:09]\nДва.")
        let lookahead = try NSRegularExpression(pattern: MeetingMarkdown.diskTurnLookahead)
        let all = NSRange(two.startIndex..., in: two)
        XCTAssertEqual(lookahead.numberOfMatches(in: two, range: all), 2)

        // И ростер, собранный с того же вывода writer'а.
        XCTAssertEqual(RecapDocument.participants(fromTranscript: two), ["Левон", "Мария"])
    }

    // MARK: - Who spoke

    /// `Speaker N` is the diarizer admitting it has no name. Listing it under
    /// **Participants** would present a placeholder as a person.
    func testAPlaceholderIsNotAParticipant() {
        XCTAssertEqual(MeetingMarkdown.extractSpeakers(from: transcript), ["Левон", "Мария"])
    }

    /// The stems path — diarization never ran — labels every remark «Собеседник»
    /// or «Я». Those are the same admission as `Speaker N`, and they are the
    /// ones that used to get through: into the file a person keeps, and into an
    /// Obsidian vault's frontmatter, as if they were attendees.
    func testTheStandInsOfTheStemsPathAreNotParticipantsEither() {
        let stems = "[Собеседник] [00:01]\nПривет.\n\n[Я] [00:05]\nПривет!"
        XCTAssertEqual(MeetingMarkdown.extractSpeakers(from: stems), [])
    }

    /// Dropping stand-ins must not mean dropping everybody.
    func testARealNameSurvivesBesideAStandIn() {
        let mixed = "[Собеседник] [00:01]\nа\n\n[Марина] [00:05]\nб"
        XCTAssertEqual(MeetingMarkdown.extractSpeakers(from: mixed), ["Марина"])
    }

    func testEachNameIsCountedOnce() {
        let repeated = "[Левон] [00:01]\nраз\n\n[Левон] [00:09]\nдва"
        XCTAssertEqual(MeetingMarkdown.extractSpeakers(from: repeated), ["Левон"])
    }

    // MARK: - Obsidian

    func testTheVaultFileOpensWithFrontmatter() {
        let out = MeetingMarkdown.obsidian(
            title: "Синк", transcript: "[Левон] [00:03]\nНачали.",
            recordingID: "20260820_110831", duration: 911,
            speakers: ["Левон"], notes: nil, today: "2026-08-20", linkedSpeakers: []
        )
        XCTAssertEqual(out.components(separatedBy: "\n").prefix(8).joined(separator: "\n"), """
        ---
        date: 2026-08-20
        title: "Синк"
        duration: "15 min"
        speakers: ["Левон"]
        audio_file: "20260820_110831.wav"
        tags: [meeting]
        ---
        """)
    }

    /// A quote in a title would close the YAML string early and break the file
    /// for every tool that reads it.
    func testAQuoteInTheTitleCannotBreakTheYaml() {
        let out = MeetingMarkdown.obsidian(
            title: #"Разбор "Мира""#, transcript: "", recordingID: "",
            duration: 0, speakers: [], notes: nil, today: "2026-08-20", linkedSpeakers: []
        )
        XCTAssertTrue(out.contains(#"title: "Разбор 'Мира'""#))
    }

    func testAPersonWithAPageBecomesALink() {
        let out = MeetingMarkdown.obsidian(
            title: "Синк", transcript: "[Левон] [00:03]\nНачали.", recordingID: "",
            duration: 0, speakers: ["Левон"], notes: nil, today: "2026-08-20",
            linkedSpeakers: [("Левон", "levon")]
        )
        XCTAssertTrue(out.contains("speakers: [\"[[levon|Левон]]\"]"))
        XCTAssertTrue(out.contains("[[levon|Левон]] [00:03]"))
    }

    // MARK: - Names into filenames

    /// Measured, not intended: diacritic folding takes the breve off `й`, so the
    /// slug reads `наиму`. Harmless where a slug is only ever a filename, and
    /// written down here so nobody later reads it as corruption.
    func testATitleBecomesAFilenameThatSurvivesAnyFilesystem() {
        XCTAssertEqual(MeetingMarkdown.slugify("Синк по найму!"), "синк-по-наиму")
        XCTAssertEqual(MeetingMarkdown.slugify("A  B / C"), "a-b-c")
        XCTAssertEqual(MeetingMarkdown.slugify("---"), "")
    }

    func testASpeakerSlugMatchesAPageName() {
        XCTAssertEqual(MeetingMarkdown.speakerSlug("Ivan Petrov"), "ivan-petrov")
        XCTAssertEqual(MeetingMarkdown.speakerSlug("Ünal O'Neil"), "unal-oneil")
    }

    /// This archive is Russian. Under the old ASCII alphabet every Cyrillic name
    /// slugged to the empty string, so linking a speaker to their page in a
    /// vault could not fire once — the feature was dead for its own audience.
    func testACyrillicNameSlugsToSomething() {
        XCTAssertEqual(MeetingMarkdown.speakerSlug("Левон"), "левон")
        XCTAssertEqual(MeetingMarkdown.speakerSlug("Марина Примерова"), "марина-примерова")
    }
}
