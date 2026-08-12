import XCTest
@testable import PropellerPure

/// Названо по тому, что человек читает в транскрипте: одна строка — один
/// говорящий. Случаи взяты из настоящей расшифровки, присланной тестировщиком, —
/// там в семи строках из восьми говорили двое.
final class StemMergeTests: XCTestCase {

    private func owner(_ start: Double, _ end: Double, _ text: String) -> StemMerge.Line {
        StemMerge.Line(start: start, end: end, speaker: "Левон", text: text)
    }

    private func far(_ start: Double, _ end: Double, _ text: String,
                     _ who: String = "Speaker S1") -> StemMerge.Line {
        StemMerge.Line(start: start, end: end, speaker: who, text: text)
    }

    /// Главное свойство: чужая реплика не может оказаться внутри моей. Ровно это
    /// сейчас и происходит — «— Угу. — Мне пон прикол… — Да, хорошо.» одной
    /// строкой под одним именем.
    func testРепликиРазныхЛюдейНеСливаются() {
        let merged = StemMerge.merge(
            owner: [owner(10, 12, "Угу"), owner(13, 15, "Да, хорошо")],
            others: [far(12.2, 12.9, "Мне пон прикол")]
        )
        XCTAssertEqual(merged.map(\.speaker), ["Левон", "Speaker S1", "Левон"])
        XCTAssertEqual(merged.map(\.text), ["Угу", "Мне пон прикол", "Да, хорошо"])
    }

    /// ASR режет речь по дыханию. Без склейки лента рассыпается на обрывки в три
    /// слова, и конспект читает их как отдельные мысли.
    func testСоседниеРепликиОдногоЧеловекаСливаются() {
        let merged = StemMerge.merge(
            owner: [owner(0, 3, "мне надо в курсах быть, что происходит,"),
                    owner(3.4, 5, "чтобы не проебаться")],
            others: []
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "мне надо в курсах быть, что происходит, чтобы не проебаться")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 5)
    }

    /// Та же фраза, но между половинами ответил другой человек: склеивать
    /// теперь нельзя, иначе его ответ уедет из ленты.
    func testПаузаСЧужимОтветомНеСклеивается() {
        let merged = StemMerge.merge(
            owner: [owner(0, 3, "мне надо в курсах быть,"), owner(3.4, 5, "чтобы не проебаться")],
            others: [far(3.0, 3.3, "Угу")]
        )
        XCTAssertEqual(merged.map(\.speaker), ["Левон", "Speaker S1", "Левон"])
    }

    func testДлиннаяПаузаРазрываетРеплику() {
        let merged = StemMerge.merge(
            owner: [owner(0, 3, "первое"), owner(30, 32, "второе")],
            others: []
        )
        XCTAssertEqual(merged.count, 2)
    }

    /// Одновременная речь — это две реплики, а не одна: они и были двумя.
    func testОдновременнаяРечьОстаётсяДвумяСтроками() {
        let merged = StemMerge.merge(
            owner: [owner(10, 14, "я думаю мы движемся в эту сторону")],
            others: [far(11, 13, "и дальше общайся, если он будет раздавать")]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.speaker), ["Левон", "Speaker S1"])
    }

    func testЛентаИдётПоВремени() {
        let merged = StemMerge.merge(
            owner: [owner(20, 21, "третье"), owner(0, 1, "первое")],
            others: [far(10, 11, "второе")]
        )
        XCTAssertEqual(merged.map(\.text), ["первое", "второе", "третье"])
    }

    /// Несколько собеседников на дальней стороне остаются разными людьми — той
    /// самой третьей стороной, которую диаризация по миксу сливает в одну.
    func testНесколькоСобеседниковНеСливаютсяМеждуСобой() {
        let merged = StemMerge.merge(
            owner: [],
            others: [far(0, 2, "давай теперь ты", "Speaker S1"),
                     far(2.2, 4, "ага, сейчас", "Speaker S2")]
        )
        XCTAssertEqual(merged.map(\.speaker), ["Speaker S1", "Speaker S2"])
    }

    func testПустыеВходыИПустойТекст() {
        XCTAssertTrue(StemMerge.merge(owner: [], others: []).isEmpty)
        XCTAssertTrue(StemMerge.merge(owner: [owner(0, 1, "   ")], others: []).isEmpty)
    }

    /// То, ради чего всё делалось: в собранной ленте смешанных строк нет.
    /// На нынешнем транскрипте эта же величина даёт 68–87 %.
    func testВСобраннойЛентеНетСмешанныхСтрок() {
        let ownerLines = [owner(0, 3, "мне надо в курсах быть"), owner(4, 6, "чтобы не проебаться")]
        let farLines = [far(3.1, 3.9, "угу"), far(6.5, 8, "понял, давай")]
        let merged = StemMerge.merge(owner: ownerLines, others: farLines)
        XCTAssertEqual(StemMerge.mixedLines(merged, against: ownerLines + farLines), 0)
    }
}
