import XCTest
import PropellerPure

/// Имя встречи берёт клавиатуру, только когда его попросили мышью.
final class TitleFocusPolicyTests: XCTestCase {

    /// Окно встало на экран и само раздало фокус первому полю.
    func testAWindowComingForwardDoesNotOpenTheNameForEditing() {
        XCTAssertFalse(TitleFocusPolicy.keeps(pointerOverName: false, mouseDown: false))
    }

    func testAClickOnTheNameOpensIt() {
        XCTAssertTrue(TitleFocusPolicy.keeps(pointerOverName: true, mouseDown: true))
    }

    /// Курсор уже над именем, а событие мыши до поля не дошло — щелчок всё
    /// равно был по нему.
    func testThePointerOverTheNameIsEnough() {
        XCTAssertTrue(TitleFocusPolicy.keeps(pointerOverName: true, mouseDown: false))
    }

    /// Наведение ещё не доехало, а нажатие уже пришло.
    func testAMouseDownIsEnough() {
        XCTAssertTrue(TitleFocusPolicy.keeps(pointerOverName: false, mouseDown: true))
    }
}
