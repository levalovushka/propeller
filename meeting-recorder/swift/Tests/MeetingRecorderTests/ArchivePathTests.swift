import XCTest
@testable import PropellerPure

/// Названо по тому, что человек увидел: «у меня потёрлись все прошлые встречи».
/// Не потёрлись — 13 записей, 42 файла стемов и 30 заметок лежали на месте.
/// Приложение смотрело в каталог `recordings ` с хвостовым пробелом, потому что
/// пробел попал в поле пути в настройках (2026-07-29).
final class ArchivePathTests: XCTestCase {

    private let fallback = "/Users/x/.meeting-recorder/recordings"

    /// Тот самый случай: один невидимый символ — и это уже другой каталог.
    func testATrailingSpaceDoesNotSendTheArchiveToANeighbouringFolder() {
        XCTAssertEqual(
            ArchivePath.normalized("/Users/x/.meeting-recorder/recordings ", default: fallback),
            "/Users/x/.meeting-recorder/recordings"
        )
    }

    func testALeadingSpaceIsTrimmedToo() {
        XCTAssertEqual(
            ArchivePath.normalized("  /Users/x/archive", default: fallback),
            "/Users/x/archive"
        )
    }

    /// Путь мог приехать из буфера обмена вместе с переводом строки.
    func testANewlineFromAPastedPathIsTrimmed() {
        XCTAssertEqual(
            ArchivePath.normalized("/Users/x/archive\n", default: fallback),
            "/Users/x/archive"
        )
    }

    /// Поле стёрли целиком. Пустая строка — это не «пиши в корень», а «верни
    /// как было по умолчанию».
    func testAnEmptyFieldFallsBackInsteadOfWritingToTheRoot() {
        XCTAssertEqual(ArchivePath.normalized("", default: fallback), fallback)
        XCTAssertEqual(ArchivePath.normalized("   ", default: fallback), fallback)
        XCTAssertEqual(ArchivePath.normalized(nil, default: fallback), fallback)
    }

    /// Пробелы **внутри** пути — это законные пробелы: у людей бывает
    /// «~/Yandex.Disk/Мои встречи». Резать можно только по краям.
    func testSpacesInsideAPathAreLeftAlone() {
        XCTAssertEqual(
            ArchivePath.normalized("/Users/x/Мои встречи/записи ", default: fallback),
            "/Users/x/Мои встречи/записи"
        )
    }

    /// Здоровый путь не должен меняться вообще.
    func testAGoodPathIsReturnedUntouched() {
        XCTAssertEqual(ArchivePath.normalized(fallback, default: "/other"), fallback)
    }
}
