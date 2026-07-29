import XCTest
@testable import PropellerPure

/// Названо по тому, чем это грозит: ScreenCaptureKit отдавал звук приложения
/// вместе с хелперами, а звонок Zoom играет именно хелпер (`CptHost`, замерено
/// на живом звонке 2026-07-29). Промахнись тап мимо него — и запись выйдет с
/// одним владельцем и тишиной вместо собеседников.
final class TapTargetTests: XCTestCase {

    private func proc(_ id: UInt32, _ bundle: String?, _ exe: String? = nil) -> AudioProcessCandidate {
        AudioProcessCandidate(objectID: id, bundleID: bundle, executableName: exe)
    }

    func testAZoomCallTapsZoom() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(1, "com.apple.Music"), proc(2, "us.zoom.xos")],
                callInProgressOn: "zoom"
            ),
            .processes([2])
        )
    }

    /// Тот самый хелпер: своего bundle id у него нет в таблице, но он —
    /// идентификатор приложения с суффиксом.
    func testZoomsCallHelperIsTappedThroughItsBundlePrefix() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(7, "us.zoom.xos.CptHost")],
                callInProgressOn: "zoom"
            ),
            .processes([7])
        )
    }

    /// Хелпер без bundle id вовсе — узнаётся по имени процесса, и это ровно тот
    /// список, что уже есть в таблице платформ для детектора.
    func testAHelperWithNoBundleIdIsFoundByItsProcessName() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(9, nil, "CptHost")],
                callInProgressOn: "zoom"
            ),
            .processes([9])
        )
    }

    /// Приложение и его хелпер звучат одновременно — тап нужен на оба, иначе
    /// пропадёт то системный звук уведомлений встречи, то сама речь.
    func testBothTheAppAndItsHelperAreTappedTogether() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(1, "us.zoom.xos"), proc(2, "us.zoom.xos.CptHost"), proc(3, "com.spotify.client")],
                callInProgressOn: "zoom"
            ),
            .processes([1, 2])
        )
    }

    /// Префикс без точки — это другое приложение. `ru.kontur.talkative` не Толк.
    func testAPrefixWithoutADotIsADifferentApp() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(4, "ru.kontur.talkative")],
                callInProgressOn: "kontur-talk"
            ),
            .everythingExceptOurselves
        )
    }

    /// Звонка нет — человек записывает подкаст или вебинар. Сузиться не на что,
    /// и это не отказ: записать надо именно машину.
    func testWithoutACallWeRecordTheMachine() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(1, "us.zoom.xos")],
                callInProgressOn: nil
            ),
            .everythingExceptOurselves
        )
    }

    /// Встреча в браузере: звонок засекли, десктопного приложения не звучит.
    /// Браузер вне области (AUDIO-CAPTURE-CASES.md), пишем машину целиком.
    func testABrowserCallFallsBackToTheWholeMachine() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(1, "com.apple.Safari")],
                callInProgressOn: "kontur-talk"
            ),
            .everythingExceptOurselves
        )
    }

    /// Регистр приводит вход, а не таблица — то же правило, что и везде.
    func testMatchingIgnoresCase() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(5, "US.Zoom.XOS")],
                callInProgressOn: "zoom"
            ),
            .processes([5])
        )
    }

    /// Идёт звонок в Толке, параллельно звучит Zoom. Писать чужой разговор мы
    /// не подписывались.
    func testOnlyTheAppWhoseCallIsUpIsTapped() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(1, "us.zoom.xos"), proc(2, "ru.kontur.talk")],
                callInProgressOn: "kontur-talk"
            ),
            .processes([2])
        )
    }

    /// Пустой bundle id (так Core Audio отвечает про часть системных процессов)
    /// не должен совпасть ни с чем через префикс.
    func testAnEmptyBundleIdMatchesNothing() {
        XCTAssertEqual(
            TapTargetPolicy.target(
                processes: [proc(1, ""), proc(2, nil, "")],
                callInProgressOn: "zoom"
            ),
            .everythingExceptOurselves
        )
    }
}
