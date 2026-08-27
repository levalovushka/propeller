import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Числа макета 312:11129, которые иначе разъезжаются молча.
///
/// Голова меряется зондом (`PaneProbe`) — у SwiftUI-вью нет своего `NSView`.
/// Тело меряется `NSLayoutManager`'ом по той же attributed-строке, что кладётся
/// в редактор: зазоры становятся арифметикой, а не сканом растра по яркости.
final class SummaryPaneLayoutTests: XCTestCase {

    private let width = Tokens.Pane.paneMeasure
    private let height: CGFloat = 900

    // MARK: - Голова

    @MainActor
    func testTheHeadStandsWhereTheCompsPutIt() throws {
        let probes = probe()
        let meta = try XCTUnwrap(probes[PaneProbe.meta], "строка атрибутов не измерена")
        let title = try XCTUnwrap(probes[PaneProbe.title], "имя встречи не измерено")

        XCTAssertEqual(meta.minX, Tokens.Pane.summaryHPadding, accuracy: 0.5)
        XCTAssertEqual(title.minX, Tokens.Pane.summaryHPadding, accuracy: 0.5)
        XCTAssertEqual(meta.minY, Tokens.Pane.paneTopPadding, accuracy: 0.5)
        XCTAssertEqual(meta.height, Tokens.Pane.Meta.height, accuracy: 0.5)
        XCTAssertEqual(title.minY - meta.maxY, Tokens.Pane.titleGap, accuracy: 0.5)
    }

    /// Бокс имени назван макетом, а не выведен из шрифта.
    ///
    /// Ровно та ловушка, что записана в `SettingsLayoutTests`: SF на 22 pt
    /// рисует 26 там, где макет даёт 24, и всё, что ниже имени, уехало бы на
    /// эти два. Тест краснеет, если бокс отдадут шрифту обратно.
    @MainActor
    func testTheTitlesBoxIsNamedByTheCompsAndNotByTheFace() throws {
        let title = try XCTUnwrap(probe()[PaneProbe.title])
        XCTAssertEqual(title.height, Tokens.Pane.Typo.paneTitle.lineHeight, accuracy: 0.5)
        XCTAssertNotEqual(
            Tokens.Pane.Typo.paneTitle.lineHeight,
            Tokens.Pane.Typo.paneTitle.renderedLineHeight,
            "если шрифт вдруг стал рисовать ровно 24, этот тест больше ничего не стережёт"
        )
    }

    /// Единственное место панели, где поле не 40: угол прижат к кромке блока.
    @MainActor
    func testTheButtonsHugTheBlocksCorner() throws {
        let actions = try XCTUnwrap(probe()[PaneProbe.actions], "кнопки не измерены")
        XCTAssertEqual(width - actions.maxX, 0, accuracy: 0.5)
        XCTAssertEqual(actions.minY, 0, accuracy: 0.5)
        // Инсет внутри самого кластера, не снаружи: так кнопка ловит нажатие
        // до самой кромки.
        XCTAssertEqual(actions.height, Tokens.Pane.headerButtonSide + Tokens.Pane.paneActionsInset * 2, accuracy: 0.5)
    }

    // MARK: - Тело

    @MainActor
    func testTheRhythmOfASectionIsTheOneTheCompsDrew() {
        let text = SummaryText.attributed(Self.document, colour: .white)
        let rects = paragraphRects(text)
        // 0 лид · 1 «Решения» · 2, 3 пункты · 4 «Задачи» · 5 пункт
        XCTAssertEqual(rects.count, 6)

        XCTAssertEqual(
            rects[1].minY - rects[0].maxY, Tokens.Pane.summarySectionGap, accuracy: 0.6,
            "раздел отбивается от предыдущего на 36"
        )
        XCTAssertEqual(
            rects[2].minY - rects[1].maxY, Tokens.Pane.summaryHeadingGap, accuracy: 0.6,
            "заголовок раздела стоит в 8 над первым пунктом"
        )
        XCTAssertEqual(
            rects[3].minY - rects[2].maxY, Tokens.Pane.summaryItemGap, accuracy: 0.6,
            "пункты внутри раздела — через 20"
        )
        XCTAssertEqual(
            rects[4].minY - rects[3].maxY, Tokens.Pane.summarySectionGap, accuracy: 0.6
        )
    }

    /// Мера текста — 569, то есть 649 минус два поля по 40.
    func testTheMeasureIsTheBlockMinusItsMargins() {
        XCTAssertEqual(Tokens.Pane.summaryMaxWidth, 569)
        XCTAssertEqual(Tokens.Pane.paneMeasure, 649)
        XCTAssertEqual(
            Tokens.Pane.paneMeasure - Tokens.Pane.summaryHPadding * 2,
            Tokens.Pane.summaryMaxWidth
        )
    }

    // MARK: - Приборы

    @MainActor
    private func probe() -> [String: CGRect] {
        var collected: [String: CGRect] = [:]
        let root = MeetingPaneBody(
            identity: .init(meetingID: "probe", title: "Базированный утренник", onRename: { _, _ in }),
            meta: .init(date: Date(timeIntervalSince1970: 1_787_412_600), people: 6),
            share: .init("Поделиться") {},
            summary: Self.document
        )
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(PaneProbeKey.self) { collected = $0 }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        // `close()` у программно созданного окна освобождает его, а ARC держит
        // ссылку дальше — второй такой замер в одном процессе падает по
        // SIGSEGV. Окно не закрывается вовсе: оно и не показывается.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // Доставка префов асинхронна.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        return collected
    }

    /// Прямоугольник каждого абзаца на мере колонки.
    private func paragraphRects(_ text: NSAttributedString) -> [CGRect] {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: Tokens.Pane.summaryMaxWidth, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return SummaryText.paragraphRanges(in: text.string).map { range in
            layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        }
    }

    private static let document = SummaryDocument.parse(markdown: """
    ## Итог
    Обсуждали переработку дизайна главной страницы приложения.

    ## Решения
    - Отказались от идеи зацикленного «барабана».
    - Решили использовать плотную сетку из чипсов.

    ## Задачи
    - **Даня Москаленко** — уточнить у Арины детали оплаты.
    """)
}
