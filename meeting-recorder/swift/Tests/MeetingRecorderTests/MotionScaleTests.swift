import XCTest
import PropellerUI

/// # Движение идёт по лестнице, а не по вкусу
///
/// До лестницы в приложении жило четырнадцать длительностей, и половина из них
/// различалась только на бумаге: 0.08 против 0.09, 0.12 против 0.13, 0.16
/// против 0.18. На экране это одна и та же скорость, названная тремя числами, —
/// то есть три ручки там, где ручка одна, и три места, где следующая правка
/// разъедется.
///
/// Отступы и радиусы у нас давно снапятся к шкале. Это то же правило для
/// времени.
final class MotionScaleTests: XCTestCase {

    private let steps: Set<Double> = [
        Tokens.Motion.Step.t60,
        Tokens.Motion.Step.t90,
        Tokens.Motion.Step.t120,
        Tokens.Motion.Step.t180,
        Tokens.Motion.Step.t240,
        Tokens.Motion.Step.t320,
        Tokens.Motion.Step.t550,
    ]

    /// Каждая длительность в приложении — ступень лестницы. Новую заводить
    /// нельзя: если движение не встаёт ни на одну, вопрос не в числе.
    func testEveryDurationIsAStepOnTheLadder() {
        let named: [(String, Double)] = [
            ("Motion.hover", Tokens.Motion.hover),
            ("Motion.press", Tokens.Motion.press),
            ("Motion.release", Tokens.Motion.release),
            ("Motion.sidebarToggle", Tokens.Motion.sidebarToggle),
            ("Motion.promptDock", Tokens.Motion.promptDock),
            ("Motion.listReflow", Tokens.Motion.listReflow),
            ("Motion.Ash.duration", Tokens.Motion.Ash.duration),
            ("Pane.followScroll", Tokens.Pane.followScroll),
            ("Pane.columnSwapOut", Tokens.Pane.columnSwapOut),
            ("Pane.columnSwapIn", Tokens.Pane.columnSwapIn),
            ("Pane.meetingSwapOut", Tokens.Pane.meetingSwapOut),
            ("Pane.meetingSwapIn", Tokens.Pane.meetingSwapIn),
            ("Pane.Bar.fadeOut", Tokens.Pane.Bar.fadeOut),
            ("Pane.Bar.fadeIn", Tokens.Pane.Bar.fadeIn),
            ("Pane.Bar.fadeInDelay", Tokens.Pane.Bar.fadeInDelay),
            ("Pane.Switcher.fade", Tokens.Pane.Switcher.fade),
            ("Window.swapOut", Tokens.Window.swapOut),
            ("Window.swapIn", Tokens.Window.swapIn),
        ]
        for (name, value) in named {
            XCTAssertTrue(
                steps.contains(value),
                "\(name) = \(value) — не ступень лестницы (\(steps.sorted()))"
            )
        }
    }

    /// Соседние ступени различимы. Меньше чем в полтора раза — и это одна
    /// скорость под двумя именами, ровно то, от чего лестница избавляет.
    func testTheStepsAreFarEnoughApartToBeTold() {
        let ladder = steps.sorted()
        for (a, b) in zip(ladder, ladder.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                b / a, 1.3,
                "\(a) и \(b) читаются как одна скорость"
            )
        }
    }

    /// Всё, кроме пепла, укладывается в 320 мс. Пепел — единственное движение,
    /// которое человек видит раз за встречу, и единственное, которому позволено
    /// длиться дольше отклика.
    func testOnlyTheAshIsAllowedToOutstayTheResponse() {
        for step in steps where step > Tokens.Motion.Step.t320 {
            XCTAssertEqual(step, Tokens.Motion.Ash.duration)
        }
    }
}
