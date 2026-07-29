import XCTest
@testable import PropellerPure

/// Названо по тому, что видел человек: звонок в Толке писался целиком с машины,
/// вместе с музыкой и уведомлениями, потому что захват знал только про Zoom.
final class CaptureScopeTests: XCTestCase {

    func testZoomCallIsScopedToZoom() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(
                runningBundleIDs: ["com.apple.finder", "us.zoom.xos"],
                callInProgressOn: "zoom"
            ),
            .applications(["us.zoom.xos"])
        )
    }

    /// Тот самый случай: Толк известен детектору, значит должен быть известен и
    /// захвату — иначе таблица платформ существует наполовину.
    func testKonturTalkCallIsScopedToo() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(
                runningBundleIDs: ["ru.kontur.talk"],
                callInProgressOn: "kontur-talk"
            ),
            .applications(["ru.kontur.talk"])
        )
    }

    /// Zoom висит открытым у всех и всегда. Сузиться на него без звонка — значит
    /// аккуратно записать тишину вместо подкаста, который человек и хотел снять.
    func testAppRunningWithoutACallDoesNotNarrowAnything() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["us.zoom.xos"], callInProgressOn: nil),
            .wholeMachine
        )
    }

    /// Идёт звонок в одном, параллельно открыт второй мессенджер — его разговоры
    /// записывать мы не подписывались.
    func testOnlyTheAppWhoseCallIsUpGetsRecorded() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(
                runningBundleIDs: ["us.zoom.xos", "ru.kontur.talk"],
                callInProgressOn: "kontur-talk"
            ),
            .applications(["ru.kontur.talk"])
        )
    }

    /// Звонок засекли по вкладке браузера: десктопного приложения нет, сузиться
    /// не на что. Браузер — вне области, пишем машину и говорим об этом честно.
    func testABrowserCallFallsBackToTheWholeMachine() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(
                runningBundleIDs: ["com.apple.Safari"],
                callInProgressOn: "kontur-talk"
            ),
            .wholeMachine
        )
    }

    /// Правило таблицы: регистр приводит вход, а не таблица.
    func testMatchingIgnoresCaseButKeepsTheSystemsSpelling() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["US.Zoom.xOS"], callInProgressOn: "zoom"),
            .applications(["US.Zoom.xOS"])
        )
    }

    /// Политика вообще не знает про громкость — тишина в приложении встречи это
    /// тишина, а не повод переключиться на всю машину.
    func testScopeDoesNotDependOnAnythingBeingAudible() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["us.zoom.xos"], callInProgressOn: "zoom"),
            .applications(["us.zoom.xos"])
        )
    }

    func testUnknownPlatformIdIsNotTrusted() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["us.zoom.xos"], callInProgressOn: "webex"),
            .wholeMachine
        )
    }
}
