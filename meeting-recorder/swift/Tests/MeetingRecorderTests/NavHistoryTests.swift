import XCTest
@testable import PropellerPure

/// Стек «Назад» / «Вперёд» — два шеврона в навбаре.
final class NavHistoryTests: XCTestCase {

    private func history(_ places: [String]) -> NavHistory<String> {
        var stack = NavHistory<String>()
        for place in places { stack.record(place) }
        return stack
    }

    /// До первого перехода назад идти некуда — и это не то же самое, что
    /// «стоим на первом месте»: пустая история и история из одного места
    /// одинаково не дают шага назад, но по разным причинам.
    func testAnEmptyHistoryGoesNowhere() {
        var stack = NavHistory<String>()
        XCTAssertNil(stack.current)
        XCTAssertFalse(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)
        XCTAssertNil(stack.back())
        XCTAssertNil(stack.forward())

        stack.record("a")
        XCTAssertEqual(stack.current, "a")
        XCTAssertFalse(stack.canGoBack)
    }

    func testTheWalkGoesBothWays() {
        var stack = history(["a", "b", "c"])
        XCTAssertEqual(stack.back(), "b")
        XCTAssertEqual(stack.back(), "a")
        XCTAssertFalse(stack.canGoBack)
        XCTAssertEqual(stack.forward(), "b")
        XCTAssertEqual(stack.forward(), "c")
        XCTAssertFalse(stack.canGoForward)
    }

    /// Шаг некуда не двигает палец: иначе «Назад» на первом месте уводил бы
    /// историю в состояние, из которого «Вперёд» показывает не то, что было.
    func testAStepIntoNothingMovesNothing() {
        var stack = history(["a", "b"])
        XCTAssertEqual(stack.back(), "a")
        XCTAssertNil(stack.back())
        XCTAssertEqual(stack.current, "a")
        XCTAssertEqual(stack.forward(), "b")
    }

    /// Панель сообщает о себе на каждое изменение состояния, а не только на
    /// переход. Без этого правила «Назад» уводил бы на ту же встречу столько
    /// раз, сколько раз в ней что-нибудь дрогнуло.
    func testTheSamePlaceTwiceIsOneStop() {
        var stack = history(["a", "a", "a", "b", "b"])
        XCTAssertEqual(stack.places, ["a", "b"])
        XCTAssertEqual(stack.back(), "a")
    }

    /// Повтор не текущего места — настоящий переход: вернуться к встрече,
    /// которую уже открывали, значит встать в историю ещё раз.
    func testReturningToAnOlderPlaceIsANewStop() {
        var stack = history(["a", "b", "a"])
        XCTAssertEqual(stack.places, ["a", "b", "a"])
        XCTAssertEqual(stack.back(), "b")
    }

    /// Ушли назад и свернули в сторону — то, что было впереди, больше не было.
    func testTurningAsideForgetsTheBranchAhead() {
        var stack = history(["a", "b", "c"])
        _ = stack.back()
        stack.record("d")
        XCTAssertEqual(stack.places, ["a", "b", "d"])
        XCTAssertFalse(stack.canGoForward)
        XCTAssertEqual(stack.back(), "b")
    }

    // MARK: - Удалённая встреча

    /// «Назад» не должен открывать то, чего больше нет.
    func testADeletedPlaceLeavesTheHistoryEntirely() {
        var stack = history(["a", "b", "a", "c"])
        stack.forget { $0 == "a" }
        XCTAssertEqual(stack.places, ["b", "c"])
        XCTAssertEqual(stack.current, "c")
        XCTAssertEqual(stack.back(), "b")
    }

    /// Выброшенное слева двигает палец: без поправки он остался бы на прежнем
    /// числе и указывал бы на чужое место.
    func testForgettingShiftsTheFingerByWhatWasDroppedBeforeIt() {
        var stack = history(["a", "b", "c"])
        _ = stack.back()
        XCTAssertEqual(stack.current, "b")
        stack.forget { $0 == "a" }
        XCTAssertEqual(stack.current, "b")
        XCTAssertFalse(stack.canGoBack)
        XCTAssertEqual(stack.forward(), "c")
    }

    /// Забыли то, на чём стояли, — палец сползает на соседа слева, а не
    /// повисает за краем.
    func testForgettingWhereWeStandLandsOnTheNeighbour() {
        var stack = history(["a", "b"])
        stack.forget { $0 == "b" }
        XCTAssertEqual(stack.places, ["a"])
        XCTAssertEqual(stack.current, "a")
        XCTAssertFalse(stack.canGoForward)
    }

    func testForgettingEverythingLeavesNoHistoryAtAll() {
        var stack = history(["a", "a"])
        stack.forget { _ in true }
        XCTAssertTrue(stack.places.isEmpty)
        XCTAssertNil(stack.current)
        XCTAssertFalse(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)
    }
}
