import XCTest
import SwiftUI
import AppKit
@testable import PropellerUI

/// Карточка пунктов в точках — Figma 297:25130 (задачи) и 297:25206 (решения).
///
/// Числа сняты с экспорта макета, а не с глаза. Держат они ровно то, что глазом
/// не проверить: на какой вертикали начинается текст, и стоит ли строка
/// «Добавить…» на той же сетке, что пункты над ней. Один раз это уже разъехалось
/// — шаг у строки добавления стоял 6 вместо 10, и её слово было на четыре точки
/// левее всех остальных.
///
/// Ширина 577 — карточка в макете при панели 649.
final class ProjectAtomLayoutTests: XCTestCase {

    private let cardWidth: CGFloat = 577

    /// Левый край текстовой колонки: поле карточки + маркер + зазор.
    private var textColumn: CGFloat {
        Tokens.Projects.Atom.cardPadding
            + Tokens.Projects.Atom.markerSide
            + Tokens.Projects.Atom.markerGap
    }

    @MainActor
    private func render(_ view: some View, height: CGFloat) -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, .dark)
                .frame(width: cardWidth, height: height, alignment: .top)
                .background(Color.black)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// Самый левый пиксель ярче порога в полосе строк `rows`, правее `from`.
    ///
    /// Порог, а не «непрозрачность»: карточка сама залита 7 %, чип — ещё 10 %
    /// поверх, буква — 90 %. Разные пороги ловят разные слои одной картинки.
    private func leftEdge(
        _ rep: NSBitmapImageRep, rows: ClosedRange<CGFloat>, brighterThan level: CGFloat,
        from: CGFloat = 0
    ) -> CGFloat? {
        let scale = CGFloat(rep.pixelsWide) / cardWidth
        for x in Int(from * scale)..<rep.pixelsWide {
            for y in Int(rows.lowerBound * scale)...Int(rows.upperBound * scale) {
                guard y < rep.pixelsHigh,
                      let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.brightnessComponent > level { return CGFloat(x) / scale }
            }
        }
        return nil
    }

    /// Карточка с одним пунктом и строкой добавления — минимум, на котором
    /// видна вся сетка.
    private var card: some View {
        ProjectAtomCard {
            ProjectAtomRow(
                checkbox: true, done: false,
                text: "Уточнить у Арины детали оплаты",
                assignee: "Даня Москаленко",
                remove: {}
            )
            ProjectAtomAddRow { _ in }
        }
    }

    // MARK: -

    /// Чип ответственного начинается там же, где текст пункта, — на 40 от края
    /// карточки (14 поля + 16 маркер + 10 зазор, 297:25136 стоит на x = 40).
    /// Чип, а не буква: у заливки нет боковой полуоткрытой доли, и её край —
    /// единственное место сетки, которое можно измерить точно.
    @MainActor
    func testЧипОтветственногоСтоитНаЛевойКромкеТекста() {
        let rep = render(card, height: 200)
        // Полоса заведомо внутри чипа: он лежит под первой строкой текста
        // (14 поля + 16 строка + 8 зазор = 38) и высотой 24.
        let chipTop = Tokens.Projects.Atom.cardPadding
            + Tokens.Projects.Typo.title.lineHeight
            + Tokens.Projects.Atom.chipGap
        let band = (chipTop + 4)...(chipTop + Tokens.Projects.Atom.Chip.height - 4)
        let left = leftEdge(rep, rows: band, brighterThan: 0.12)
        XCTAssertNotNil(left, "чип не найден вовсе")
        XCTAssertEqual(left ?? -1, textColumn, accuracy: 1,
                       "чип начинается на \(left ?? -1), сетка текста — \(textColumn)")
    }

    /// «Добавить…» стоит на той же вертикали, что и текст пункта.
    ///
    /// Та самая ошибка: шаг у строки добавления был свой (6), и слово выезжало
    /// левее всей карточки. Сравниваются две буквы одной кегли, поэтому боковая
    /// доля начертания у обеих одна и в разность не входит.
    @MainActor
    func testСтрокаДобавленияСтоитНаСеткеПунктов() {
        let rep = render(card, height: 200)
        let itemTop = Tokens.Projects.Atom.cardPadding
        let itemBand = (itemTop + 3)...(itemTop + Tokens.Projects.Typo.title.lineHeight - 3)
        // Строка добавления: поле + строка + зазор чипа + чип + зазор строк.
        let addTop = Tokens.Projects.Atom.cardPadding
            + Tokens.Projects.Typo.title.lineHeight
            + Tokens.Projects.Atom.chipGap
            + Tokens.Projects.Atom.Chip.height
            + Tokens.Projects.Atom.rowGap
        let addBand = (addTop + 3)...(addTop + Tokens.Projects.Typo.title.lineHeight - 3)

        // Правее маркерной колонки: слева в обеих строках стоит свой значок.
        let after = Tokens.Projects.Atom.cardPadding + Tokens.Projects.Atom.markerSide + 2
        let item = leftEdge(rep, rows: itemBand, brighterThan: 0.5, from: after)
        let add = leftEdge(rep, rows: addBand, brighterThan: 0.25, from: after)
        XCTAssertNotNil(item, "текст пункта не найден")
        XCTAssertNotNil(add, "«Добавить…» не найдено")
        XCTAssertEqual(add ?? -1, item ?? -2, accuracy: 1.5,
                       "«Добавить…» на \(add ?? -1), пункт на \(item ?? -1)")
        XCTAssertEqual(item ?? -1, textColumn, accuracy: 2,
                       "текст на \(item ?? -1), сетка — \(textColumn)")
    }

    /// Карточка занимает всю отведённую ширину и не оставляет полей по бокам:
    /// поле у неё внутреннее, и второе, снаружи, сдвинуло бы весь столбец.
    @MainActor
    func testКарточкаЗанимаетВсюШирину() {
        let rep = render(card, height: 200)
        let scale = CGFloat(rep.pixelsWide) / cardWidth
        let y = Int((Tokens.Projects.Atom.cardPadding + 20) * scale)
        var left = CGFloat(-1), right = CGFloat(-1)
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.brightnessComponent > 0.03 {
                if left < 0 { left = CGFloat(x) / scale }
                right = CGFloat(x + 1) / scale
            }
        }
        XCTAssertEqual(left, 0, accuracy: 0.6, "левый край карточки \(left)")
        XCTAssertEqual(right, cardWidth, accuracy: 0.6, "правый край карточки \(right)")
    }
}
