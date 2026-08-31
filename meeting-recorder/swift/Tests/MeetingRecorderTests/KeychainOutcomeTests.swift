import XCTest
@testable import PropellerPure

/// «Ключа нет» и «ключ не отдали» — разные ответы.
///
/// До 31 августа Keychain-помощник не различал их вовсе: любой отказ становился
/// `nil`, `nil` становился «провайдера нет», встреча молча парковалась. За 60
/// дней восемь человек выбрали облачный провайдер и не получили ни одного
/// конспекта — и понять, вписали они ключ или нет, по этим данным нельзя.
final class KeychainOutcomeTests: XCTestCase {

    /// `errSecInteractionNotAllowed` — заперт логин-кейчейн.
    private let denied: Int32 = -25308

    // MARK: - Запись

    /// Элемента нет — это приглашение добавить, а не отказ.
    func testAMissingItemIsAnInvitationToAddIt() {
        XCTAssertEqual(KeychainOutcome.afterUpdate(KeychainOutcome.notFound), .add)
        XCTAssertEqual(KeychainOutcome.afterUpdate(KeychainOutcome.success), .done)
    }

    /// Отказ обязан остаться отказом. Если считать его за «элемента нет», код
    /// пойдёт добавлять поверх — а старая запись «удалить, потом добавить» на
    /// этом месте оставляла человека вообще без ключа, который уже работал.
    func testARefusalIsNeverReadAsAMissingItem() {
        XCTAssertEqual(KeychainOutcome.afterUpdate(denied), .refused(denied))
        XCTAssertNotEqual(KeychainOutcome.afterUpdate(denied), .add)
        XCTAssertEqual(KeychainOutcome.afterAdd(denied), .refused(denied))
        XCTAssertEqual(KeychainOutcome.afterAdd(KeychainOutcome.success), .done)
    }

    // MARK: - Чтение

    func testReadingTellsAbsenceApartFromRefusal() {
        XCTAssertEqual(KeychainOutcome.afterRead(KeychainOutcome.success, gotData: true), .found)
        XCTAssertEqual(KeychainOutcome.afterRead(KeychainOutcome.notFound, gotData: false), .absent)
        XCTAssertEqual(KeychainOutcome.afterRead(denied, gotData: false), .refused(denied))
    }

    /// «Нашёл, но данных нет» — это сломанный ответ, а не пустой ящик. Молчание
    /// здесь и есть то, из-за чего причина пустого поля неизвестна.
    func testSuccessWithoutDataIsARefusalRatherThanAnEmptyBox() {
        XCTAssertEqual(
            KeychainOutcome.afterRead(KeychainOutcome.success, gotData: false),
            .refused(KeychainOutcome.success)
        )
    }
}
