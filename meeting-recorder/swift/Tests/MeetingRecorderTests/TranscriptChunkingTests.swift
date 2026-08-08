import XCTest
@testable import PropellerPure

/// Названо по тому, что теряет человек, когда нарезки нет: вторую половину
/// собственной встречи. Проверяется не «сколько кусков вышло», а что ни одна
/// реплика не разрезана и ни одна не потеряна — всё остальное следствие.
final class TranscriptChunkingTests: XCTestCase {

    private func transcript(turns: Int, wordsPerTurn: Int = 40) -> String {
        var text = """
        # Встреча

        **Date:** 2026-08-08
        **Participants:** Левон

        ## Transcript

        """
        for i in 0..<turns {
            let minute = String(format: "%02d:%02d", i / 60, i % 60)
            let speaker = i.isMultiple(of: 2) ? "Левон" : "Speaker S1"
            text += "**\(speaker)** · \(minute)\n"
            text += Array(repeating: "слово\(i)", count: wordsPerTurn).joined(separator: " ") + "\n\n"
        }
        return text
    }

    func testКороткийТранскриптОстаётсяЦелым() {
        let text = transcript(turns: 5)
        XCTAssertEqual(TranscriptChunking.split(text), [text])
    }

    func testНиОднаРепликаНеРазрезана() {
        let chunks = TranscriptChunking.split(transcript(turns: 200), charactersPerChunk: 5_000)
        XCTAssertGreaterThan(chunks.count, 1, "длинная встреча обязана разрезаться")
        for chunk in chunks.dropFirst() {
            XCTAssertTrue(chunk.hasPrefix("**"),
                          "фрагмент начинается не с реплики: «\(chunk.prefix(40))»")
        }
    }

    /// Потерянная реплика — потерянная договорённость, и заметить это по
    /// готовому конспекту невозможно.
    func testВсеРепликиДоживаютДоФрагментов() {
        let text = transcript(turns: 200)
        let chunks = TranscriptChunking.split(text, charactersPerChunk: 5_000)
        XCTAssertEqual(chunks.joined(), text)

        let expected = text.components(separatedBy: "**Левон** ·").count - 1
        let actual = chunks.reduce(0) { $0 + $1.components(separatedBy: "**Левон** ·").count - 1 }
        XCTAssertEqual(actual, expected)
    }

    /// Шапка нужна первому фрагменту, чтобы модель знала, чья это встреча, и не
    /// нужна остальным — там она только занимает окно.
    func testШапкаТолькоВПервомФрагменте() {
        let chunks = TranscriptChunking.split(transcript(turns: 200), charactersPerChunk: 5_000)
        XCTAssertTrue(chunks[0].contains("**Participants:** Левон"))
        for chunk in chunks.dropFirst() {
            XCTAssertFalse(chunk.contains("Participants"))
        }
    }

    func testРепликаДлиннееФрагментаНеТеряется() {
        let text = transcript(turns: 3, wordsPerTurn: 3_000)
        let chunks = TranscriptChunking.split(text, charactersPerChunk: 1_000)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(chunks.count, 3)
    }

    func testПустойИБезРепликНеПадают() {
        XCTAssertEqual(TranscriptChunking.split(""), [])
        XCTAssertEqual(TranscriptChunking.split("   \n  "), [])
        let noTurns = "# Встреча\n\n## Transcript\n\nтекст без реплик\n"
        XCTAssertEqual(TranscriptChunking.split(noTurns), [noTurns])
    }

    /// Порог тот же, что у `OllamaContext`: резать надо ровно тогда, когда иначе
    /// модель молча потеряет начало.
    func testРезатьНадоТогдаЖеКогдаОкноПереполняется() {
        let fits = 30_000
        let overflows = 200_000
        XCTAssertFalse(TranscriptChunking.needed(promptCharacters: fits))
        XCTAssertTrue(TranscriptChunking.needed(promptCharacters: overflows))
        XCTAssertEqual(TranscriptChunking.needed(promptCharacters: overflows),
                       OllamaContext.exceedsLargestWindow(promptCharacters: overflows))
    }

    /// Фрагмент подобран так, чтобы всегда влезать в маленькое окно: это и
    /// качество извлечения, и 0,7 ГБ памяти, которые иначе платятся за 32768.
    func testФрагментВлезаетВМаленькоеОкно() {
        let promptOverhead = 2_000
        let window = OllamaContext.numCtx(
            promptCharacters: TranscriptChunking.charactersPerChunk + promptOverhead
        )
        XCTAssertEqual(window, 16_384)
    }
}
