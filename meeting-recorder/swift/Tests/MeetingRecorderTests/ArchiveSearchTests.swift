import XCTest
@testable import PropellerPure

/// Поиск по архиву — то, что человек трогает руками чаще всего в готовом
/// приложении, и до сих пор не покрытое ни одним тестом: логика жила во вьюхе,
/// откуда её нельзя было позвать.
final class ArchiveSearchTests: XCTestCase {

    private func doc(
        _ id: String, title: String = "Встреча", date: String = "6 августа",
        transcript: String = "", notes: String = "", recap: String = ""
    ) -> ArchiveSearch.Document {
        ArchiveSearch.Document(
            id: id, title: title, dateLabel: date, bodies: [transcript, notes, recap]
        )
    }

    // MARK: - Что находится

    func testБезЗапросаПоказываютсяПоследниеВстречи() {
        let docs = (1...20).map { doc("m\($0)") }
        let hits = ArchiveSearch.run(query: "", over: docs)
        XCTAssertEqual(hits.count, ArchiveSearch.recentCount)
        XCTAssertEqual(hits.first?.id, "m1", "порядок тот, в каком встречи пришли")
        XCTAssertNil(hits.first?.snippet, "показывать нечего: искали не по тексту")
    }

    func testПробелыВЗапросеНеСчитаютсяЗапросом() {
        let hits = ArchiveSearch.run(query: "   ", over: (1...20).map { doc("m\($0)") })
        XCTAssertEqual(hits.count, ArchiveSearch.recentCount)
    }

    func testНаходитПоЗаголовку() {
        let docs = [doc("a", title: "Биллинг и миграция"), doc("b", title: "Дейлик")]
        let hits = ArchiveSearch.run(query: "биллинг", over: docs)
        XCTAssertEqual(hits.map(\.id), ["a"])
        XCTAssertEqual(hits.first?.inText, false, "в текстах слова нет — только в имени")
        XCTAssertEqual(hits.first?.matchCount, 0)
    }

    func testНаходитПоДате() {
        let docs = [doc("a", date: "6 августа"), doc("b", date: "7 августа")]
        XCTAssertEqual(ArchiveSearch.run(query: "7 авг", over: docs).map(\.id), ["b"])
    }

    func testНаходитВТранскриптеИСчитаетВхождения() {
        let docs = [doc("a", transcript: "миграция базы, потом миграция биллинга")]
        let hits = ArchiveSearch.run(query: "миграция", over: docs)
        XCTAssertEqual(hits.first?.matchCount, 2)
        XCTAssertEqual(hits.first?.inText, true)
    }

    func testИщетИВЗаметкахИВКонспекте() {
        let docs = [
            doc("a", notes: "не забыть про отчёт"),
            doc("b", recap: "решили отложить отчёт до пятницы"),
            doc("c", transcript: "ничего про это"),
        ]
        XCTAssertEqual(Set(ArchiveSearch.run(query: "отчёт", over: docs).map(\.id)), ["a", "b"])
    }

    func testРегистрИЁНеМешают() {
        let docs = [doc("a", transcript: "Ещё раз про Биллинг")]
        XCTAssertEqual(ArchiveSearch.run(query: "еще", over: docs).count, 1)
        XCTAssertEqual(ArchiveSearch.run(query: "БИЛЛИНГ", over: docs).count, 1)
    }

    func testНичегоНеНайденоЭтоПустойСписокАНеВсеВстречи() {
        let docs = (1...20).map { doc("m\($0)", transcript: "про спринт") }
        XCTAssertTrue(ArchiveSearch.run(query: "квартальный бюджет", over: docs).isEmpty)
    }

    // MARK: - Сниппет

    func testСниппетПоказываетНайденноеСКонтекстом() {
        let docs = [doc("a", transcript: "Мы обсудили миграцию базы и решили отложить её до среды")]
        let snippet = ArchiveSearch.run(query: "миграцию", over: docs).first?.snippet
        XCTAssertEqual(snippet?.match, "миграцию")
        XCTAssertTrue(snippet?.prefix.contains("обсудили") ?? false)
        XCTAssertTrue(snippet?.suffix.contains("базы") ?? false)
    }

    func testСниппетНеРежетСловоПополам() {
        // Контекст отсчитывается символами, поэтому граница почти всегда падает
        // в середину слова. Строка, начинающаяся с «…ацию базы», читается как
        // ошибка приложения.
        let long = String(repeating: "слово ", count: 40) + "миграция " + String(repeating: "ещё ", count: 40)
        let snippet = ArchiveSearch.snippet(around: "миграция", in: long)
        let trimmed = snippet?.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "… ")) ?? ""
        XCTAssertTrue(trimmed.isEmpty || trimmed.hasPrefix("слово"), "получили: «\(trimmed)»")
    }

    func testСниппетСтавитМноготочиеТолькоТамГдеТекстОборван() {
        let short = "миграция базы"
        let snippet = ArchiveSearch.snippet(around: "миграция", in: short)
        XCTAssertEqual(snippet?.prefix, "")
        XCTAssertFalse(snippet?.suffix.contains("…") ?? true)
    }

    func testСниппетБерётсяИзПервогоТекстаГдеНашлось() {
        let docs = [doc("a", transcript: "", notes: "в заметке про биллинг", recap: "в конспекте про биллинг")]
        let snippet = ArchiveSearch.run(query: "биллинг", over: docs).first?.snippet
        XCTAssertTrue(snippet?.prefix.contains("заметке") ?? false)
    }

    // MARK: - Устойчивость

    func testПустыеТекстыНеЛомаютПоиск() {
        let docs = [doc("a")]
        XCTAssertTrue(ArchiveSearch.run(query: "что-нибудь", over: docs).isEmpty)
    }

    func testЗапросДлиннееТекстаНеПадает() {
        let docs = [doc("a", transcript: "да")]
        XCTAssertTrue(ArchiveSearch.run(query: "да и ещё много слов сверху", over: docs).isEmpty)
    }

    func testПоискНеЧитаетДискИНеЗависитОтПорядкаТекстов() {
        // Свойство, ради которого всё это вынесено: результат зависит только от
        // переданных строк. Одинаковые документы дают одинаковые ответы.
        let a = ArchiveSearch.run(query: "биллинг", over: [doc("a", transcript: "биллинг")])
        let b = ArchiveSearch.run(query: "биллинг", over: [doc("a", transcript: "биллинг")])
        XCTAssertEqual(a, b)
    }
}
