import XCTest
@testable import PropellerPure

/// Паритет механической сборки с эталоном `tools/recap-lab` (Г1): фикстуры
/// перенесены из `test_parse.py` дословно. Разбор форм экстрактора ломался там
/// **четырежды**, каждый раз новой формой одного ярлыка — все четыре здесь,
/// плюс пятая неизвестная. Пятая форма найдётся, но не молча: тест падает,
/// а не выдаёт ярлык пользователю.
final class RecapAssemblyTests: XCTestCase {

    // MARK: - Формы экстрактора

    func testInlineListSplitsIntoThreeItems() {
        let items = RecapAssembly.itemsFromFacts(
            "ДОГОВОРИЛИСЬ: каталог остаётся единым; корзина не меняется; главную переделываем")
        XCTAssertEqual(items["Решения"],
                       ["каталог остаётся единым", "корзина не меняется", "главную переделываем"])
    }

    func testLabelThenBullets() {
        let items = RecapAssembly.itemsFromFacts(
            "ЗАДАЧА:\n- Оля посчитает смету сегодня вечером\n- Левон проверит тексты завтра")
        XCTAssertEqual(items["Задачи"],
                       ["Оля посчитает смету сегодня вечером", "Левон проверит тексты завтра"])
    }

    func testContinuationLineWithoutBulletStaysInSection() {
        let items = RecapAssembly.itemsFromFacts(
            "ОТКРЫТО: куда девать карусель акций\nсколько шагов в чекауте на самом деле")
        XCTAssertEqual(items["Открытые вопросы"],
                       ["куда девать карусель акций", "сколько шагов в чекауте на самом деле"])
    }

    /// Форма 4 (регресс из JUDGE.md): метка внутри буллета. Пункты расходятся
    /// по своим секциям, и ярлык не попадает в текст ни одного пункта.
    func testLabelInsideBulletRoutesAndNeverLeaksTheLabel() {
        let facts = """
        ОТКРЫТО: оценка функционала для раздела декоративной косметики
        - ДОГОВОРИЛИСЬ: отпустить Левона на клиентскую работу; два плана оценки
        - ЗАДАЧА: Оля посчитает итоговые цифры сегодня или завтра до 12:30
        - ТЕМА: обсуждение оставшихся купе и сметы на завтра
        """
        let items = RecapAssembly.itemsFromFacts(facts)
        XCTAssertEqual(items["Решения"],
                       ["отпустить Левона на клиентскую работу", "два плана оценки"])
        XCTAssertEqual(items["Задачи"],
                       ["Оля посчитает итоговые цифры сегодня или завтра до 12:30"])
        XCTAssertEqual(items["Открытые вопросы"],
                       ["оценка функционала для раздела декоративной косметики"])
        XCTAssertEqual(items["Ход обсуждения"],
                       ["обсуждение оставшихся купе и сметы на завтра"])
        for (section, texts) in items {
            for text in texts {
                for label in ["ДОГОВОРИЛИСЬ", "ЗАДАЧА", "ОТКРЫТО", "ТЕМА"] {
                    XCTAssertFalse(text.uppercased().contains(label),
                                   "ярлык «\(label)» уехал в конспект дословно: [\(section)] \(text)")
                }
            }
        }
    }

    func testBoldLabelIsStillALabel() {
        let items = RecapAssembly.itemsFromFacts("**ЗАДАЧА:** Левон соберёт макеты к среде")
        XCTAssertEqual(items["Задачи"], ["Левон соберёт макеты к среде"])
    }

    /// Пятая метка вне четырёх: текст сохраняется, ярлык — нет.
    func testUnknownLabelKeepsBodyDropsLabel() {
        let items = RecapAssembly.itemsFromFacts(
            "ЗАДАЧА: Левон соберёт макеты к среде\n- ИТОГ: встречаемся завтра в 12:30")
        XCTAssertEqual(items["Задачи"],
                       ["Левон соберёт макеты к среде", "встречаемся завтра в 12:30"])
    }

    func testEmptyMarkerLineIsSkipped() {
        let items = RecapAssembly.itemsFromFacts("ПУСТО")
        XCTAssertTrue((items["Решения"] ?? []).isEmpty)
        XCTAssertTrue((items["Ход обсуждения"] ?? []).isEmpty)
    }

    // MARK: - Проза: одна хронология, не две

    func testProseLinesWithoutTimecodeContinueTheirBlock() {
        let lines = ["**Тема раз (05:14 – 12:13)**", "Тело первого абзаца.",
                     "**14:57 – 20:34**: тело второго абзаца.", "*   подпункт второго"]
        XCTAssertEqual(RecapAssembly.proseBlocks(lines),
                       ["**Тема раз (05:14 – 12:13)**\nТело первого абзаца.",
                        "**14:57 – 20:34**: тело второго абзаца.\n*   подпункт второго"])
    }

    func testChronologyNeverRollsBackAndNothingIsLost() {
        let t0 = ["Ход обсуждения": ["**00:15 – 06:28**: начало", "**20:46 – 23:32**: смета"]]
        let sample = ["Ход обсуждения": ["**Концепция (05:14 – 12:13)**", "Тело.",
                                         "**26:57 – конец**: презентация"]]
        let facts = ["Ход обсуждения": ["The act | декор. косметика"]]
        let merged = RecapAssembly.mergeProse([t0, sample, facts])
        let starts = merged.compactMap { RecapAssembly.blockSpan($0)?.start }
        XCTAssertEqual(starts, starts.sorted(), "хронология откатилась назад")
        XCTAssertEqual(merged.count, 5, "блок потерян при слиянии")
        XCTAssertEqual(merged.last, "The act | декор. косметика", "блок без таймкода не в конце")
    }

    /// Срок в теле абзаца («завтра в 12:30») — не заголовок: блок не должен
    /// уезжать в чужое место хронологии.
    func testDeadlineInsideBodyIsNotABlockHead() {
        XCTAssertFalse(RecapAssembly.blockHead(
            "и договорились посчитать смету завтра к 12:30 после дейлика"))
        XCTAssertTrue(RecapAssembly.blockHead("**00:15 – 06:28**: начало"))
        XCTAssertTrue(RecapAssembly.blockHead("**Тема раз (05:14 – 12:13)**"))
    }

    // MARK: - Дедуп: дубль лучше пропуска, но точный дубль схлопывается

    func testNearDuplicateKeepsTheLongerWording() {
        let branch = ["Решения": ["релиз переносится на пятницу",
                                  "релиз переносится на пятницу окончательно",
                                  "метрики выносятся в отдельную встречу"]]
        let merged = RecapAssembly.merge([branch])
        XCTAssertEqual(merged["Решения"],
                       ["релиз переносится на пятницу окончательно",
                        "метрики выносятся в отдельную встречу"])
    }

    func testDifferentItemsSurviveTheMerge() {
        let branch = ["Задачи": ["Оля посчитает смету сегодня вечером",
                                 "Левон соберёт макеты к среде"]]
        XCTAssertEqual(RecapAssembly.merge([branch])["Задачи"]?.count, 2)
    }

    // MARK: - Паритет с эталоном на живом входе стенда (Г1)

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MeetingRecorderTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/recap-assembly/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Живой выход экстрактора со стенда собирается в тот же документ, что
    /// python-эталон, **байт в байт**. Как снят эталон — README рядом с
    /// фикстурой. Разъехались — порт молча разошёлся со стендом; чинить порт,
    /// не фикстуру.
    func testLiveStandInputAssemblesByteForByteLikePython() throws {
        let facts = try fixture("facts-live.md")
        let expected = try fixture("expected-live.md")
        XCTAssertEqual(RecapAssembly.assemble(facts: facts), expected)
    }

    // MARK: - Рендер

    func testRenderSkipsEmptySectionsAndKeepsOrder() {
        let facts = """
        ДОГОВОРИЛИСЬ: каталог остаётся единым до конца года
        ЗАДАЧА: Оля посчитает смету сегодня вечером
        ТЕМА: **00:15 – 06:28**: обсуждение каталога и сметы
        """
        let body = RecapAssembly.assemble(facts: facts)
        let headings = body.split(separator: "\n").filter { $0.hasPrefix("## ") }
        XCTAssertEqual(headings, ["## Решения", "## Задачи", "## Ход обсуждения"])
        XCTAssertTrue(body.contains("- каталог остаётся единым до конца года"))
        XCTAssertFalse(body.contains("## Итог"), "Итог — проза, механическая сборка её не пишет")
    }
}
