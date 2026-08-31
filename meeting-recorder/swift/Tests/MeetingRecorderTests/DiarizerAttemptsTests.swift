import XCTest
@testable import PropellerPure

/// Правило, из-за отсутствия которого один тестировщик получил 25 падений
/// подряд: работа, способная убить процесс, обязана оставить след до начала.
final class DiarizerAttemptsTests: XCTestCase {

    func testНаЧистойМашинеДиаризацияРаботает() {
        XCTAssertTrue(DiarizerAttempts().mayRun)
    }

    func testОдноПадениеЕщёНеПриговор() {
        // ⌘Q посреди работы, сон машины, кончилось питание — начатая и не
        // закрытая попытка бывает и без падения.
        var a = DiarizerAttempts()
        a.starting()
        XCTAssertTrue(DiarizerAttempts(unfinished: a.unfinished).mayRun)
    }

    func testДваПаденияПодрядВыключаютКластеризацию() {
        var a = DiarizerAttempts()
        a.starting()
        var next = DiarizerAttempts(unfinished: a.unfinished)
        next.starting()
        XCTAssertFalse(DiarizerAttempts(unfinished: next.unfinished).mayRun)
    }

    func testВернулисьЖивымиИСчётОбнулился() {
        var a = DiarizerAttempts()
        a.starting()
        a.returned()
        XCTAssertEqual(a.unfinished, 0)
        XCTAssertTrue(a.mayRun)
    }

    func testБрошеннаяОшибкаНеСчитаетсяСмертью() {
        // Мы считаем только то, из чего не вернулись. Ошибка — это возврат.
        var a = DiarizerAttempts(unfinished: 1)
        a.starting()
        a.returned()
        XCTAssertTrue(a.mayRun)
    }

    func testИспорченныйСчётчикНеЛомаетПродукт() {
        // Файл могли обнулить, стереть или испортить руками.
        XCTAssertTrue(DiarizerAttempts(unfinished: -5).mayRun)
        XCTAssertEqual(DiarizerAttempts(unfinished: -5).unfinished, 0)
    }

    func testЛестницаИсполнителей() {
        // Здоровая машина не платит за чужую беду ничем.
        XCTAssertEqual(DiarizerAttempts().plan, .standard)
        // Одна смерть — тот же проход, другой исполнитель.
        XCTAssertEqual(DiarizerAttempts(unfinished: 1).plan, .alternateEngine)
        // Две — кластеризации нет, спикеры по дорожкам.
        XCTAssertEqual(DiarizerAttempts(unfinished: 2).plan, .skip)
        XCTAssertEqual(DiarizerAttempts(unfinished: 9).plan, .skip)
    }

    func testПланИРазрешениеНеРасходятся() {
        // `plan == .skip` и `mayRun == false` обязаны означать одно и то же:
        // два способа спросить об одном не должны отвечать по-разному.
        for n in 0...5 {
            let a = DiarizerAttempts(unfinished: n)
            XCTAssertEqual(a.plan == .skip, !a.mayRun, "разошлись на \(n)")
        }
    }

    func testВыключеннаяКластеризацияНеВключаетсяСама() {
        // Пока никто не обнулил счётчик, каждая следующая встреча идёт по
        // дорожкам, а не пробует снова и снова.
        let stuck = DiarizerAttempts(unfinished: DiarizerAttempts.limit + 3)
        XCTAssertFalse(stuck.mayRun)
    }

    // MARK: - Дефект 4: первые две смерти процесса были невидимы

    /// Метка ставится **до** вызова, который на macOS 14 убивает процесс
    /// сигналом. Сигнал не перехватить, телеметрия уходит батчем и асинхронно —
    /// значит из умирающего процесса рассказать нельзя ничем, и первые две
    /// смерти не оставляли следа: `disabled_after_crash` приходил только на
    /// третьем заходе. Наблюдено 6 таких событий у 2 человек, то есть минимум
    /// 12 ненаблюдаемых смертей, каждая из которых снаружи выглядела как
    /// «расшифровка не запускалась».
    ///
    /// Достижимо здесь ровно одно: рассказать задним числом. Метка смерть
    /// переживает, и следующий живой процесс её читает.
    func testНезакрытаяПопыткаПревращаетсяВСтупеньДляТелеметрии() {
        XCTAssertNil(DiarizerAttempts.deathStage(unfinished: 0), "рассказывать не о чем")
        XCTAssertEqual(DiarizerAttempts.deathStage(unfinished: 1), "died_once")
        XCTAssertEqual(DiarizerAttempts.deathStage(unfinished: 2), "died_twice")
        XCTAssertEqual(
            DiarizerAttempts.deathStage(unfinished: DiarizerAttempts.limit + 5), "died_twice",
            "выше предела ступени нет — кластеризация уже выключена"
        )
    }

    /// Каждая ступень обязана иметь имя: молчание на какой-нибудь из них и есть
    /// та самая невидимая смерть.
    func testУКаждойСмертиЕстьИмя() {
        for n in 1...(DiarizerAttempts.limit + 3) {
            XCTAssertNotNil(DiarizerAttempts.deathStage(unfinished: n), "молчим на \(n)")
        }
    }

    /// Счётчик у выключенной кластеризации стоит двойкой навсегда: докладывать о
    /// нём на каждом запуске значило бы делать самый безнадёжный случай самым
    /// громким в статистике — ровно то, от чего лечит `TelemetryNoise`.
    func testОСмертиДокладываютОдинРазНаИнцидент() {
        XCTAssertTrue(TelemetryNoise.reportsDiarizerDeath(unfinished: 1, lastReported: nil))
        XCTAssertFalse(TelemetryNoise.reportsDiarizerDeath(unfinished: 1, lastReported: 1))
        XCTAssertTrue(
            TelemetryNoise.reportsDiarizerDeath(unfinished: 2, lastReported: 1),
            "вторая смерть — другой инцидент"
        )
        XCTAssertFalse(
            TelemetryNoise.reportsDiarizerDeath(unfinished: 0, lastReported: nil),
            "живой возврат — не смерть"
        )
    }
}
