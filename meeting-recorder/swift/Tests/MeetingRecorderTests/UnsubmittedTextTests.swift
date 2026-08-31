import XCTest
import SwiftUI
import AppKit
@testable import PropellerUI

/// Набранное и оставленное без ⏎ — не пропадает.
///
/// Четыре поля из `ProjectsKit` и `SidebarPrompt` теряли ввод молча: клик мимо
/// снимал каретку, и текст, стоявший на экране, не был больше нигде. Здесь
/// проверяется то, что человек в этот момент видит, а не то, какие модификаторы
/// висят на вьюхе.
///
/// # Чем это проверяется
///
/// Настоящим окном и настоящим полем: `NSHostingView` в `borderless`-окне,
/// клик — синтетическим `NSEvent` через `NSWindow.sendEvent`, набор — в
/// редакторе поля (`NSTextField.currentEditor`). Так поднимаются три поля из
/// четырёх.
///
/// **Четвёртое — поле правки пункта (`ProjectAtomRow`) — так не поднимается.**
/// Открывает его карандаш, а карандаш живёт под курсором (`opacity(hovering)` +
/// `allowsHitTesting(hovering)`), и `onHover` на синтетических событиях не
/// срабатывает: замерено — картинка вьюхи до и после `mouseEntered` + `mouseMoved`
/// побитово одна (1838 непрозрачных пикселей в обоих случаях), значит карандаш
/// так и остался прозрачным и ненажимаемым. Поэтому у него проверяется решение
/// («во что превращается набранное»), а не проводка, и это сказано вслух, а не
/// спрятано за зелёным тестом про что-то другое.
@MainActor
final class UnsubmittedTextTests: XCTestCase {

    // MARK: - Стенд

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    private func host(_ view: some View, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
        let hosting = NSHostingView(rootView: AnyView(
            view.frame(width: size.width - 40, alignment: .topLeading).padding(20)
        ))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.25)
        return (window, hosting)
    }

    private func pump(_ seconds: TimeInterval = 0.12) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        for (type, number) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: 1
            ) { window.sendEvent(event) }
            pump(0.06)
        }
    }

    /// Набрать в поле так, как набирает человек, — в его редакторе.
    private func type(_ text: String, into field: NSTextField, of window: NSWindow) {
        window.makeFirstResponder(field)
        pump(0.08)
        field.currentEditor()?.insertText(text)
        pump(0.12)
    }

    /// Клик мимо: каретка уходит, вьюха остаётся.
    private func dropFocus(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        pump(0.2)
    }

    /// Снести вьюху под тем, в чём печатали.
    private func remove(_ hosting: NSHostingView<AnyView>) {
        hosting.rootView = AnyView(Color.clear.frame(width: 10, height: 10))
        hosting.layoutSubtreeIfNeeded()
        pump(0.25)
    }

    /// Клавиатурный тест держится на том, что окно стенда стало key.
    ///
    /// `onExitCommand` разносит SwiftUI по **своему** фокусу, а фокус он ставит
    /// только у ключевого окна. Ключ достаётся не всегда: другое приложение
    /// впереди (у нас это был запущенный Propeller), сессия без графики, CI.
    /// Тогда Escape уходит в никуда, и тест краснеет не про код, а про среду —
    /// а красный, который ничего не значит, отравляет весь набор.
    ///
    /// Поэтому проверка своего условия стоит **до** утверждения: ключ есть —
    /// тест настоящий и мутацию ловит; ключа нет — тест честно говорит, что не
    /// проверил, вместо того чтобы соврать в любую из двух сторон.
    private func requireKeyWindow(_ window: NSWindow) throws {
        try XCTSkipUnless(
            window.isKeyWindow,
            "окно стенда не стало ключевым — клавиатуру проверить нечем "
            + "(впереди другое приложение, либо сессия без графики)"
        )
    }

    private func escape(_ window: NSWindow) {
        if let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) { window.sendEvent(event) }
        pump(0.2)
    }

    // MARK: - Строка добавления пункта

    /// Набрал задачу, кликнул мимо — задача добавлена.
    ///
    /// Было: текст исчезал, пустое поле оставалось открытым, и человек узнавал
    /// об этом по тому, что задачи нет в списке.
    func testНабраннаяЗадачаДобавляетсяПриКликеМимо() {
        var added: [String] = []
        let (window, hosting) = host(
            ProjectAtomAddRow { added.append($0) }, size: NSSize(width: 340, height: 64)
        )
        click(window, at: NSPoint(x: 170, y: 32))
        guard let field = fields(hosting).first else {
            return XCTFail("поле ввода не открылось по клику")
        }
        type("Позвонить в банк", into: field, of: window)
        dropFocus(window)

        XCTAssertEqual(added, ["Позвонить в банк"])
        // И закрылось: пустая строка ввода без каретки читается как сломанная.
        XCTAssertTrue(fields(hosting).isEmpty, "поле осталось открытым без каретки")
    }

    /// Набрал задачу, и карточку под ней пересобрали — задача добавлена.
    func testНабраннаяЗадачаДобавляетсяПриСносеСтроки() {
        var added: [String] = []
        let (window, hosting) = host(
            ProjectAtomAddRow { added.append($0) }, size: NSSize(width: 340, height: 64)
        )
        click(window, at: NSPoint(x: 170, y: 32))
        guard let field = fields(hosting).first else {
            return XCTFail("поле ввода не открылось по клику")
        }
        type("Собрать смету", into: field, of: window)
        remove(hosting)

        XCTAssertEqual(added, ["Собрать смету"])
    }

    /// Пустое поле, оставленное без ввода, ничего не добавляет.
    func testПустоеПолеНичегоНеДобавляет() {
        var added: [String] = []
        let (window, hosting) = host(
            ProjectAtomAddRow { added.append($0) }, size: NSSize(width: 340, height: 64)
        )
        click(window, at: NSPoint(x: 170, y: 32))
        XCTAssertFalse(fields(hosting).isEmpty, "поле ввода не открылось по клику")
        dropFocus(window)

        XCTAssertEqual(added, [])
    }

    func testПробелыЗадачейНеСчитаются() {
        XCTAssertNil(ProjectAtomAddRow.resolve("   \n "))
        XCTAssertEqual(ProjectAtomAddRow.resolve("  Смета  "), "Смета")
    }

    // MARK: - Правка пункта

    /// Стёртый пункт — отказ от правки, а не удаление.
    func testПустаяПравкаПунктаЕгоНеТрогает() {
        XCTAssertNil(ProjectAtomRow.resolve(draft: "   ", replacing: "Собрать смету"))
        XCTAssertNil(ProjectAtomRow.resolve(draft: "", replacing: "Собрать смету"))
    }

    /// Тот же текст — не правка: файл встречи, которую никто не трогал, не
    /// переписывают.
    func testТотЖеТекстНеСчитаетсяПравкой() {
        XCTAssertNil(ProjectAtomRow.resolve(draft: "Собрать смету", replacing: "Собрать смету"))
        XCTAssertNil(ProjectAtomRow.resolve(draft: " Собрать смету ", replacing: "Собрать смету"))
    }

    /// Вставленный из письма абзац доезжает одной строкой, а не пропадает:
    /// пункт — одна строка файла.
    func testВставленныйАбзацСкладываетсяВОднуСтроку() {
        XCTAssertEqual(
            ProjectAtomRow.resolve(draft: "Собрать смету\nи отправить", replacing: "Смета"),
            "Собрать смету и отправить"
        )
    }

    // MARK: - Плита создания проекта

    /// Имя проекта живёт снаружи плиты, поэтому уход каретки его не уносит.
    func testНабранноеИмяПроектаПереживаетУходКаретки() {
        var name = ""
        var about = ""
        let (window, hosting) = host(
            ProjectComposer(
                name: Binding(get: { name }, set: { name = $0 }),
                about: Binding(get: { about }, set: { about = $0 }),
                submit: {}, cancel: {}
            ),
            size: NSSize(width: 480, height: 460)
        )
        guard let field = fields(hosting).first else { return XCTFail("нет поля имени") }
        type("Камуфляж", into: field, of: window)
        dropFocus(window)

        XCTAssertEqual(name, "Камуфляж")
    }

    /// Escape закрывает плиту из поля имени. До сегодня обработчика не было ни
    /// одного, хотя комментарий в `MainView` утверждал обратное.
    func testEscapeИзПоляИмениЗакрываетПлиту() throws {
        var name = ""
        var about = ""
        var cancelled = 0
        let (window, _) = host(
            ProjectComposer(
                name: Binding(get: { name }, set: { name = $0 }),
                about: Binding(get: { about }, set: { about = $0 }),
                submit: {}, cancel: { cancelled += 1 }
            ),
            size: NSSize(width: 480, height: 460)
        )
        try requireKeyWindow(window)
        escape(window)

        XCTAssertEqual(cancelled, 1)
    }

    // Про Escape из поля описания теста здесь нет, и это не забывчивость.
    // Каретку в `TextEditor` можно поставить только кликом: `makeFirstResponder`
    // двигает первого отвечающего AppKit, а SwiftUI разносит `onExitCommand` по
    // **своему** фокусу — проверено мутацией, снятый с описания обработчик не
    // менял ничего, отвечало поле имени. А клик в `NSTextView` вешает процесс
    // теста насмерть: его `mouseDown` крутит собственный цикл выборки событий,
    // а синтетические события идут мимо очереди. Поэтому обработчик там стоит
    // непроверенным, и это сказано вслух.

    // MARK: - Вопрос в подошве рельса

    private func prompt(_ id: String) -> SidebarPromptModel {
        SidebarPromptModel(
            id: id, title: "Как вас зовут?", subtitle: "Учтём в расшифровках",
            counter: "2/3", action: .field(placeholder: "Ваше имя")
        )
    }

    /// Клик мимо блок не сносит — значит и набранное остаётся на месте, в поле,
    /// под тем же вопросом. Ответом оно при этом не становится: подтверждение
    /// здесь закрывает шаг мастера и запекает имя во все будущие расшифровки.
    func testНабранноеИмяОстаётсяВПолеПослеКликаМимо() {
        var answers: [String] = []
        let (window, hosting) = host(
            SidebarPromptBlock(model: prompt("name"), onAction: { _ in },
                               onSubmit: { _, name in answers.append(name) }),
            size: NSSize(width: 300, height: 200)
        )
        guard let field = fields(hosting).first else { return XCTFail("нет поля имени") }
        type("Лёва", into: field, of: window)
        dropFocus(window)

        XCTAssertEqual(answers, [], "недонабранное имя ушло ответом по клику мимо")
        XCTAssertEqual(fields(hosting).first?.stringValue, "Лёва", "набранное стёрлось")
    }

    /// Блок сносит тумблер рельса и уход с экрана, где он стоит. Своего
    /// «Отменить» у него нет, поэтому набранное на выходе уходит ответом.
    func testНабранноеИмяУходитОтветомКогдаБлокСносят() {
        var answers: [(String, String)] = []
        let (window, hosting) = host(
            SidebarPromptBlock(model: prompt("name"), onAction: { _ in },
                               onSubmit: { answers.append(($0, $1)) }),
            size: NSSize(width: 300, height: 200)
        )
        guard let field = fields(hosting).first else { return XCTFail("нет поля имени") }
        type("  Лёва Лобанов  ", into: field, of: window)
        remove(hosting)

        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.0, "name")
        XCTAssertEqual(answers.first?.1, "Лёва Лобанов")
    }

    /// Ответ уходит один раз: черновик тратится подтверждением, и снос блока
    /// следом не отправляет то же имя вторым ответом, которого никто не давал.
    func testОтветНеУходитВторойРазПриСносеБлока() {
        var answers: [String] = []
        let (window, hosting) = host(
            SidebarPromptBlock(model: prompt("name"), onAction: { _ in },
                               onSubmit: { _, name in answers.append(name) }),
            size: NSSize(width: 300, height: 200)
        )
        guard let field = fields(hosting).first else { return XCTFail("нет поля имени") }
        type("Лёва", into: field, of: window)
        field.currentEditor()?.insertNewline(nil)
        pump(0.15)
        remove(hosting)

        XCTAssertEqual(answers, ["Лёва"])
    }

    /// Пустой блок, снесённый без ввода, ответом не считается: пустое имя
    /// закрыло бы вопрос ничем.
    func testСнесённыйПустойБлокНеОтвечает() {
        var answers: [String] = []
        let (_, hosting) = host(
            SidebarPromptBlock(model: prompt("name"), onAction: { _ in },
                               onSubmit: { _, name in answers.append(name) }),
            size: NSSize(width: 300, height: 200)
        )
        remove(hosting)

        XCTAssertEqual(answers, [])
    }

    /// Смена вопроса стирает набранное, а не отправляет его: вопрос про имя
    /// уходит с экрана ровно тогда, когда на него ответили в настройках, и
    /// коммит на этой развилке затирал бы названное имя недонабранным.
    func testСменаВопросаСтираетНабранноеИНеОтвечает() {
        var answers: [String] = []
        var model = prompt("name")
        let holder = ModelHolder(model)
        let (window, hosting) = host(
            PromptHost(holder: holder, onSubmit: { answers.append($0) }),
            size: NSSize(width: 300, height: 200)
        )
        guard let field = fields(hosting).first else { return XCTFail("нет поля имени") }
        type("Лёва", into: field, of: window)
        model = SidebarPromptModel(
            id: "claude", title: "Подключите Claude", subtitle: "Он будет в курсе ваших встреч",
            counter: "3/3", action: .field(placeholder: "Ваше имя")
        )
        holder.model = model
        pump(0.25)

        XCTAssertEqual(answers, [], "недонабранное имя ушло ответом на смене вопроса")
        XCTAssertEqual(fields(hosting).first?.stringValue, "", "черновик пережил смену вопроса")
    }

    func testПробелыИменемНеСчитаются() {
        XCTAssertNil(SidebarPromptBlock.resolve("   "))
        XCTAssertEqual(SidebarPromptBlock.resolve("  Лёва "), "Лёва")
    }
}

/// Держатель модели: смену вопроса надо сделать *внутри* живой вьюхи, а не
/// пересозданием — иначе проверялось бы пересоздание, а не `onChange`.
@MainActor
private final class ModelHolder: ObservableObject {
    @Published var model: SidebarPromptModel
    init(_ model: SidebarPromptModel) { self.model = model }
}

private struct PromptHost: View {
    @ObservedObject var holder: ModelHolder
    let onSubmit: (String) -> Void

    var body: some View {
        SidebarPromptBlock(model: holder.model, onAction: { _ in },
                           onSubmit: { _, name in onSubmit(name) })
    }
}
