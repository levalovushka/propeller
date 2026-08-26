import XCTest
import CoreGraphics
@testable import PropellerPure

/// Решётку статусной иконки глазами не проверить: она 16 pt и всё время в
/// движении. Проверяет её тест — тем, что спрашивает у функции координаты.
final class StatusLatticeTests: XCTestCase {

    private let side: CGFloat = 16

    func testEveryStateDrawsBothRings() {
        for status in PropellerStatus.allCases {
            let dots = PropellerLattice.dots(status: status, size: side, time: 3.2)
            XCTAssertEqual(dots.count, PropellerLattice.dotCount,
                           "\(status.rawValue): решётка — это два кольца по шесть точек")
        }
    }

    func testTheSameMomentDrawsTheSameFrame() {
        // Иначе кадры нельзя ни сэмплировать в слой, ни снять для галереи.
        for status in PropellerStatus.allCases {
            let a = PropellerLattice.dots(status: status, size: side, time: 7.75)
            let b = PropellerLattice.dots(status: status, size: side, time: 7.75)
            XCTAssertEqual(a, b, status.rawValue)
        }
    }

    func testNothingLeavesTheBox() {
        // Точка вылезшая за квадрат обрежется по-разному в строке и в галерее.
        for status in PropellerStatus.allCases {
            for step in 0..<240 {
                let time = Double(step) * 0.05
                for (i, dot) in PropellerLattice.dots(status: status, size: side, time: time).enumerated() {
                    let where_ = "\(status.rawValue) точка \(i) на \(time) с"
                    XCTAssertGreaterThanOrEqual(dot.x - dot.radius, 0, where_)
                    XCTAssertGreaterThanOrEqual(dot.y - dot.radius, 0, where_)
                    XCTAssertLessThanOrEqual(dot.x + dot.radius, side, where_)
                    XCTAssertLessThanOrEqual(dot.y + dot.radius, side, where_)
                }
            }
        }
    }

    func testAlphaAndRadiusStayLegal() {
        for status in PropellerStatus.allCases {
            for step in 0..<240 {
                let time = Double(step) * 0.05
                for dot in PropellerLattice.dots(status: status, size: side, time: time) {
                    XCTAssertGreaterThan(dot.radius, 0, status.rawValue)
                    XCTAssertGreaterThanOrEqual(dot.alpha, 0, status.rawValue)
                    XCTAssertLessThanOrEqual(dot.alpha, 1, status.rawValue)
                }
            }
        }
    }

    func testOnlyIdleStandsStill() {
        // От этого зависит, будить ли таймер: у неподвижного состояния кадров нет.
        for status in PropellerStatus.allCases {
            let a = PropellerLattice.dots(status: status, size: side, time: 0)
            let b = PropellerLattice.dots(status: status, size: side, time: 0.9)
            if status == .idle {
                XCTAssertEqual(a, b, "покой не зависит от времени")
                XCTAssertFalse(PropellerLattice.isAnimated(status))
            } else {
                XCTAssertNotEqual(a, b, "\(status.rawValue) обязано двигаться")
                XCTAssertTrue(PropellerLattice.isAnimated(status))
            }
        }
    }

    func testAboveSixteenTheFigureIsOneShape() {
        // Выше 16 pt фигура — одна и та же, просто крупнее.
        let a = PropellerLattice.dots(status: .idle, size: 32, time: 0)
        let b = PropellerLattice.dots(status: .idle, size: 64, time: 0)
        for (small, large) in zip(a, b) {
            XCTAssertEqual(large.x / 64, small.x / 32, accuracy: 0.001)
            XCTAssertEqual(large.y / 64, small.y / 32, accuracy: 0.001)
            XCTAssertEqual(large.radius / 64, small.radius / 32, accuracy: 0.001)
        }
    }

    func testSixteenIsDeliberatelyFatter() {
        // И это не забытая пропорция: на 16 pt пропорциональная точка занимает
        // меньше пикселя и растворяется в сглаживании, поэтому у мелкого кегля
        // своя метрика. Тест держит развилку названной — иначе следующий, кто
        // увидит `size <= 16`, «починит» её в одну строку.
        let small = PropellerLattice.dots(status: .idle, size: 16, time: 0)
        let large = PropellerLattice.dots(status: .idle, size: 32, time: 0)
        XCTAssertGreaterThan(small[0].radius / 16, large[0].radius / 32,
                             "на 16 pt точка обязана быть крупнее по доле бокса")
    }

    func testEveryStateSaysWhatItIs() {
        // Иконка — единственное, что говорит о фазе, значит её обязан прочесть
        // и VoiceOver.
        var seen = Set<String>()
        for status in PropellerStatus.allCases {
            let label = status.accessibilityLabel
            XCTAssertFalse(label.isEmpty, status.rawValue)
            XCTAssertTrue(seen.insert(label).inserted, "«\(label)» повторяется")
        }
    }
}
