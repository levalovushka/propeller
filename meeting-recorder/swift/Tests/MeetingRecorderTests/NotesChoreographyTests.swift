import XCTest
import PropellerUI

/// # Заметки и окно — два события, а не одно
///
/// Названо тем, что видно: «окно раскрывается грубо, как шторка». Если колонка
/// проявляется ровно в такт краю окна, глаз читает одно движение — край едет и
/// вскрывает текст. Разводятся они не кривой и не хитростью, а временем, и это
/// время держится на трёх числах, каждое из которых поодиночке выглядит
/// произвольным. Отношения между ними — не выглядят.
final class NotesChoreographyTests: XCTestCase {

    private let window = Tokens.Motion.windowResize
    private let fade = Tokens.Motion.notesInkFade
    private let delay = Tokens.Motion.notesInkDelay
    private let lead = Tokens.Motion.notesInkLead

    /// Приезд заканчивается **позже**, чем встаёт окно: сначала появляется
    /// место, потом то, что в нём стоит.
    func testTheNotesFinishArrivingAfterTheWindowHasStopped() {
        XCTAssertGreaterThan(delay + fade, window)
    }

    /// Но начинается он, пока окно ещё едет, — иначе это не «чуть позже», а
    /// два хода подряд, и вся связка растягивается вдвое.
    func testTheArrivalStartsWhileTheWindowIsStillMoving() {
        XCTAssertLessThan(delay, window)
    }

    /// Уход заканчивается **раньше**, чем окно доедет: край не должен съесть
    /// строку, которую ещё читают.
    func testTheNotesAreGoneBeforeTheWindowHasFinishedClosing() {
        XCTAssertLessThan(fade, lead + window)
    }

    /// И трогается окно уже после того, как чернила пошли, а не одновременно.
    func testTheWindowSetsOffAfterTheTextHasStartedLeaving() {
        XCTAssertGreaterThan(lead, 0)
        XCTAssertLessThan(lead, fade, "Фора, а не отдельный ход.")
    }

    /// Обе связки короче полусекунды. Дольше — и это уже не отклик на нажатие,
    /// а сцена, которую пересиживают.
    func testNeitherJourneyOutstaysItsWelcome() {
        XCTAssertLessThan(delay + fade, 0.5)
        XCTAssertLessThan(lead + window, 0.5)
    }
}
