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

    func testВыключеннаяКластеризацияНеВключаетсяСама() {
        // Пока никто не обнулил счётчик, каждая следующая встреча идёт по
        // дорожкам, а не пробует снова и снова.
        let stuck = DiarizerAttempts(unfinished: DiarizerAttempts.limit + 3)
        XCTAssertFalse(stuck.mayRun)
    }
}
