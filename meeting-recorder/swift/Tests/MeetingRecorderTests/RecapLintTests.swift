import XCTest
@testable import PropellerPure

/// Названо по тому, что видит человек в готовом конспекте. Каждый случай ниже
/// пришёл из реального прогона по архиву — это то, что модель написала на самом
/// деле, а не то, что она могла бы написать.
final class RecapLintTests: XCTestCase {

    private func kinds(_ recap: String, transcript: String = "") -> [RecapLint.Kind] {
        RecapLint.findings(recap: recap, transcript: transcript).map(\.kind)
    }

    /// Худшая из выдумок: срок, которого никто не называл. Через неделю его уже
    /// не отличить от настоящего.
    func testСрокКоторогоНеБылоНаВстрече() {
        let recap = "## Задачи\n- **Левон** — прислать доки к пятнице.\n"
        let transcript = "**Левон** · 00:10\nПришлю доки, как соберу.\n"
        XCTAssertEqual(kinds(recap, transcript: transcript), [.unspokenDeadline])
    }

    func testНазванныйСрокНеСчитаетсяВыдумкой() {
        let recap = "## Задачи\n- **Левон** — прислать доки к пятнице.\n"
        let transcript = "**Левон** · 00:10\nДавай к пятнице пришлю, успею.\n"
        XCTAssertEqual(kinds(recap, transcript: transcript), [])
    }

    func testОтветственныйПризрак() {
        let recap = """
        ## Задачи
        - **Система** — подготовить документы.
        - **Слава (или участник с ответственностью)** — собрать бриф.
        """
        XCTAssertEqual(kinds(recap).filter { $0 == .ghostOwner }.count, 2)
    }

    /// Появилось, когда редактору дали инструкции приказным тоном и он перенёс
    /// тон в документ: девять таких строк на восьми встречах.
    func testПовелительноеНаклонение() {
        let recap = """
        ## Решения
        - Используйте существующий стейтбук как фундамент.
        - **Левон** — проведите очистку кода.
        """
        XCTAssertEqual(kinds(recap).filter { $0 == .imperative }.count, 2)
    }

    /// Ловушка предыдущей проверки: обычные слова, кончающиеся так же.
    func testОбычныеСловаНеПутаютсяСПриказом() {
        let recap = "## Итог\n- Договорились о работе на сайте и в чате.\n"
        XCTAssertFalse(kinds(recap).contains(.imperative))
    }

    func testПассивИКанцелярит() {
        let recap = "## Решения\n- Было решено, что смета будет подготовлена в рамках проекта.\n"
        let found = kinds(recap)
        XCTAssertTrue(found.contains(.passive))
        XCTAssertTrue(found.contains(.clerical))
    }

    /// «Данные» — это data, обычное слово встречи про продукт; канцелярит —
    /// «данный вопрос». Правило, которое их путает, портит нормальный текст.
    func testДанныеЭтоНеКанцелярит() {
        XCTAssertFalse(kinds("- Договорились хранить данные в облаке.").contains(.clerical))
        XCTAssertTrue(kinds("- Договорились закрыть данный вопрос.").contains(.clerical))
    }

    func testДлинноеПредложение() {
        let long = "- " + Array(repeating: "слово", count: 30).joined(separator: " ") + "."
        XCTAssertEqual(kinds(long), [.longSentence])
        let short = "- " + Array(repeating: "слово", count: 10).joined(separator: " ") + "."
        XCTAssertEqual(kinds(short), [])
    }

    /// Заголовок документа и блок заметок пишет приложение, а не модель.
    /// Правя их, редактор переписывал бы заметки пользователя.
    func testСистемныеБлокиНеПроверяются() {
        let recap = """
        # Встреча — рекап

        ## Решения
        - Договорились начать в понедельник.

        ## Заметки

        Было решено всё в рамках данного проекта.
        """
        let transcript = "**Левон** · 00:01\nНачнём в понедельник.\n"
        XCTAssertEqual(kinds(recap, transcript: transcript), [])
    }

    /// Список обрезается — и обрезаться должны длинные предложения, а не
    /// выдуманный срок: он дороже.
    func testСамоеВажноеНеВыпадаетИзОбрезанногоСписка() {
        var findings = (0..<40).map { RecapLint.Finding(kind: .longSentence, text: "\(25 + $0) слов") }
        findings.append(RecapLint.Finding(kind: .unspokenDeadline, text: "к пятнице"))
        let notes = RecapLint.editorNotes(findings, limit: 5)
        XCTAssertTrue(notes.contains("к пятнице"), notes)
        XCTAssertEqual(notes.components(separatedBy: "\n- ").count - 1, 5)
    }

    /// Указания редактору не должны звучать как приказ: он копирует их тон в
    /// документ. Это тот же дефект, что проверка `.imperative` ловит на выходе.
    func testУказанияРедактору_ОписываютРезультатАНеПриказывают() {
        let notes = RecapLint.editorNotes([
            .init(kind: .unspokenDeadline, text: "к пятнице"),
            .init(kind: .passive, text: "было решено"),
        ])
        for forbidden in ["убери", "перепиши", "исправь каждое", "разбей"] {
            XCTAssertFalse(notes.lowercased().contains(forbidden), "приказ в указании: \(forbidden)")
        }
        XCTAssertTrue(notes.contains("в исправленном тексте"))
    }

    func testЧистыйКонспектНеДаётУказаний() {
        let recap = "## Решения\n- Договорились отказаться от диплинков.\n"
        XCTAssertEqual(kinds(recap), [])
        XCTAssertEqual(RecapLint.editorNotes([]), "")
    }
}
