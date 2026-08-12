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
}
