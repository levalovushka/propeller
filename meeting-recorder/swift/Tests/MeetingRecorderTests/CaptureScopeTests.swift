import XCTest
@testable import PropellerPure

/// Названо по тому, что видел человек: звонок в Толке писался целиком с машины,
/// вместе с музыкой и уведомлениями, потому что захват знал только про Zoom.
final class CaptureScopeTests: XCTestCase {

    func testZoomRunningIsScopedToZoom() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["com.apple.finder", "us.zoom.xos"]),
            .applications(["us.zoom.xos"])
        )
    }

    /// Тот самый случай: Толк известен детектору, значит должен быть известен и
    /// захвату — иначе таблица платформ существует наполовину.
    func testKonturTalkIsScopedToo() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["ru.kontur.talk"]),
            .applications(["ru.kontur.talk"])
        )
    }

    func testTwoMeetingAppsRunningAreBothCaptured() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["us.zoom.xos", "ru.kontur.talk"]),
            .applications(["us.zoom.xos", "ru.kontur.talk"])
        )
    }

    /// Правило таблицы: регистр приводит вход, а не таблица. Система вправе
    /// вернуть bundle id как угодно.
    func testMatchingIgnoresCaseButKeepsTheSystemsSpelling() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["US.Zoom.xOS"]),
            .applications(["US.Zoom.xOS"])
        )
    }

    /// Единственный честный повод писать всю машину: знакомого приложения нет,
    /// а записать человек попросил.
    func testNothingKnownRunningMeansWholeMachine() {
        XCTAssertEqual(
            CaptureScopePolicy.scope(runningBundleIDs: ["com.apple.Safari", "com.spotify.client"]),
            .wholeMachine
        )
        XCTAssertEqual(CaptureScopePolicy.scope(runningBundleIDs: []), .wholeMachine)
    }

    /// Тишина в приложении встречи — это тишина, а не повод переключиться на всю
    /// машину: политика вообще не знает про громкость.
    func testScopeDoesNotDependOnAnythingBeingAudible() {
        let quiet = CaptureScopePolicy.scope(runningBundleIDs: ["us.zoom.xos"])
        XCTAssertEqual(quiet, .applications(["us.zoom.xos"]))
    }
}
