import XCTest
@testable import PropellerPure
@testable import PropellerUI

/// # ⌘Q не уносит последнюю правку
///
/// Дописал абзац в саммари, нажал ⌘Q — абзаца нет. Переименовал встречу без ⏎ —
/// имя не сохранилось. Обе потери из одного места: набранное живёт в `@State`
/// окна, записывает его `onDisappear`, а при `terminate` SwiftUI вьюхи не
/// разбирает и `onDisappear` не приходит вовсе.
///
/// # Что проверяется здесь, а что нет
///
/// Проверяется **решение**: реестр ненаписанного (`PendingEdits`) и правило
/// «пустое — не заметка» (`NoteBar.resolve`). Проводка — `AppDelegate` →
/// `AppStateRegistry` → `AppState.pendingEdits` → регистрация в `MainView` —
/// живёт в `Sources/`, которую тестовая цель не импортирует, и держится на
/// компиляции и чтении. Сказано вслух, а не спрятано за зелёным тестом про
/// что-то другое.
@MainActor
final class PendingEditsTests: XCTestCase {

    // MARK: - Реестр ненаписанного

    /// То, ради чего он есть: спросить одним движением снаружи вьюхи.
    func testФлашСпрашиваетВсехЗарегистрированных() {
        let edits = PendingEdits()
        var written: [String] = []
        edits.register("саммари") { written.append("саммари") }
        edits.register("заметка") { written.append("заметка") }

        XCTAssertEqual(edits.flush(), 2)
        XCTAssertEqual(written, ["саммари", "заметка"], "порядок регистрации не сохранён")
    }

    /// Порядок значащий: правка саммари пишет файл встречи, заметка пишет
    /// индекс, и один `flush()` индекса на выходе обязан застать обе.
    func testПорядокЭтоПорядокРегистрацииАНеСловаря() {
        let edits = PendingEdits()
        var written: [String] = []
        for key in ["я", "б", "а", "ю"] {
            edits.register(key) { written.append(key) }
        }
        edits.flush()
        XCTAssertEqual(written, ["я", "б", "а", "ю"])
    }

    /// Окно открывают и закрывают. Вторая регистрация под тем же ключом обязана
    /// **заменить** первую: замыкание держит `@State` своего окна, и старое
    /// записало бы правку окна, которого уже нет, поверх свежей.
    func testПовторнаяРегистрацияЗаменяетПрежнееОкно() {
        let edits = PendingEdits()
        var written: [String] = []
        edits.register("MainView") { written.append("старое окно") }
        edits.register("MainView") { written.append("новое окно") }

        XCTAssertEqual(edits.count, 1)
        edits.flush()
        XCTAssertEqual(written, ["новое окно"])
    }

    /// Закрытое окно уже всё записало само (`onDisappear`), и второй раз его
    /// спрашивать некому.
    func testСнятаяРегистрацияБольшеНеОтвечает() {
        let edits = PendingEdits()
        var written = 0
        edits.register("MainView") { written += 1 }
        edits.unregister("MainView")

        XCTAssertEqual(edits.flush(), 0)
        XCTAssertEqual(written, 0)
    }

    /// Приложение после флаша может и остаться жить — окно спрятали, машину
    /// усыпили. Снятая флашем регистрация означала бы, что следующая правка в
    /// том же окне снова никому не видна.
    func testФлашНеСнимаетРегистрацию() {
        let edits = PendingEdits()
        var written = 0
        edits.register("MainView") { written += 1 }

        edits.flush()
        edits.flush()
        XCTAssertEqual(written, 2)
    }

    func testПустойРеестрФлашитсяМолча() {
        XCTAssertEqual(PendingEdits().flush(), 0)
    }

    // MARK: - Черновик заметки

    /// Пустое — не заметка. На пути с выхода из приложения это важнее, чем на
    /// ⏎: там некому увидеть, что записали пустоту.
    func testПробелыЗаметкойНеСчитаются() {
        XCTAssertNil(NoteBar.resolve(""))
        XCTAssertNil(NoteBar.resolve("   "))
        XCTAssertNil(NoteBar.resolve("\n \n"))
    }

    /// Недописанное — дописывается. Ровно то, что теряло ⌘Q.
    func testНедописаннаяЗаметкаЭтоЗаметка() {
        XCTAssertEqual(NoteBar.resolve("позвонить в банк"), "позвонить в банк")
        XCTAssertEqual(NoteBar.resolve("  позвонить в банк\n"), "позвонить в банк")
    }
}
