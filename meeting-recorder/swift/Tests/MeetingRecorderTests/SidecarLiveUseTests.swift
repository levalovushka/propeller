import XCTest
@testable import PropellerPure

/// Скобка живой сессии — `PropellerPure/SidecarLiveUse.swift`.
///
/// Названо по тому, что человек видел, когда правила не было: живой текст шёл
/// 45 секунд и молча кончался. Встреча А кончилась, пошёл догон ASR; началась
/// встреча Б, воркера сняли, догон упал по отмене — и его `defer` всё равно
/// поставил остановку по простою. На 45-й секунде встречи Б сервер получал
/// SIGTERM, а лестница переподключения стучалась в мёртвый порт до конца звонка.
final class SidecarLiveUseTests: XCTestCase {

    func testПодЖивойСессиейСерверНеГаснетПоПростою() {
        var use = SidecarLiveUse()
        use.begin()
        XCTAssertFalse(
            use.mayStopOnIdle,
            "сервер не простаивает — на нём идёт лента встречи"
        )
    }

    func testПослеЗакрытияСессииГаснет() {
        var use = SidecarLiveUse()
        use.begin()
        use.end()
        XCTAssertTrue(use.mayStopOnIdle, "никто не слушает — модель обязана уйти из памяти")
    }

    func testБезСессийГаснетСразу() {
        // Обычный случай: догон по архиву кончился, встреч нет.
        XCTAssertTrue(SidecarLiveUse().mayStopOnIdle)
    }

    func testВтораяСессияДержитСерверПослеЗакрытияПервой() {
        // Догон по прошлой встрече идёт фоном, пока пишется следующая.
        var use = SidecarLiveUse()
        use.begin()
        use.begin()
        use.end()
        XCTAssertFalse(use.mayStopOnIdle, "один слушатель ещё остался")
        use.end()
        XCTAssertTrue(use.mayStopOnIdle)
    }

    func testЛишнееЗакрытиеНеОткрываетДорогуГашению() {
        // `stop()` и `end()` обе зовут close(); лишний вычет ушёл бы в минус, и
        // следующая живая сессия начиналась бы с уже разрешённым гашением.
        var use = SidecarLiveUse()
        use.end()
        use.end()
        XCTAssertEqual(use.users, 0)
        use.begin()
        XCTAssertFalse(use.mayStopOnIdle)
    }

    func testПерезапускРадиСловаряИГашениеПоПростоюСпрашиваютОдноИТоЖе() {
        // Счётчик завели ради первого, а второе его не спрашивало вовсе — вот
        // это и был дефект. Оба вопроса теперь у одного места.
        var use = SidecarLiveUse()
        XCTAssertEqual(use.mayRestartForTerms, use.mayStopOnIdle)
        use.begin()
        XCTAssertEqual(use.mayRestartForTerms, use.mayStopOnIdle)
        XCTAssertFalse(use.mayRestartForTerms)
    }
}
