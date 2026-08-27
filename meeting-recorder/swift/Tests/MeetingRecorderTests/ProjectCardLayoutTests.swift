import XCTest
import SwiftUI
import AppKit
@testable import PropellerUI

/// Карточка проекта в точках — Figma 255:5082.
///
/// Держит одну вещь, которую глаз пропустил на две недели: **меню карточки не
/// двигает её название**. Меню — квадрат в 24, строка названия — 16, и потолок,
/// поставленный на ряд вместо меню, чинил высоту и ломал положение: содержимое
/// в 24 внутри рамки в 16 SwiftUI центрирует, и название уезжало вверх, за
/// внутреннее поле карточки.
final class ProjectCardLayoutTests: XCTestCase {

    /// Колонка сетки при панели 649: (649 − 36·2 − 10) / 2.
    private let cardWidth: CGFloat = 297

    @MainActor
    private func render(menu: some View) -> NSBitmapImageRep {
        let card = ProjectCard(
            name: "Агентный дизайн",
            about: "Дизайн-язык вместо дизайн-системы.",
            footer: "Сегодня · 3 встречи",
            open: {},
            menu: { menu }
        )
        let height = Tokens.Projects.cardHeight
        let hosting = NSHostingView(
            rootView: card
                .environment(\.colorScheme, .dark)
                .frame(width: cardWidth, height: height)
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

    /// Первая строка ярче порога — верх букв. Столбцы взяты левее меню, чтобы
    /// само меню в замер не попало.
    private func firstBrightRow(_ rep: NSBitmapImageRep, brighterThan level: CGFloat) -> CGFloat? {
        let scale = CGFloat(rep.pixelsWide) / cardWidth
        for y in 0..<rep.pixelsHigh {
            for x in 0..<Int((cardWidth - 40) * scale) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.brightnessComponent > level { return CGFloat(y) / scale }
            }
        }
        return nil
    }

    /// Меню в 24 не сдвигает название ни на точку — ни вверх, ни вниз.
    @MainActor
    func testМенюКарточкиНеДвигаетЕёНазвание() {
        let without = firstBrightRow(render(menu: EmptyView()), brighterThan: 0.5)
        let with = firstBrightRow(
            render(menu: Color.clear.frame(width: 24, height: 24)), brighterThan: 0.5
        )
        XCTAssertNotNil(without, "название не найдено")
        XCTAssertEqual(with ?? -1, without ?? -2, accuracy: 0.5,
                       "с меню название на \(with ?? -1), без меню — на \(without ?? -1)")
    }

    /// И стоит оно внутри поля карточки, а не над ним. Порог свободный:
    /// проверяется не метрика шрифта, а то, что буквы ниже кромки поля.
    @MainActor
    func testНазваниеСтоитВнутриПоляКарточки() {
        let top = firstBrightRow(
            render(menu: Color.clear.frame(width: 24, height: 24)), brighterThan: 0.5
        )
        XCTAssertNotNil(top)
        XCTAssertGreaterThanOrEqual(
            top ?? 0, Tokens.Projects.cardVPadding,
            "верх букв на \(top ?? -1) при поле \(Tokens.Projects.cardVPadding)"
        )
        XCTAssertLessThan(
            top ?? 99,
            Tokens.Projects.cardVPadding + Tokens.Projects.Typo.title.lineHeight,
            "название провалилось ниже своей строки"
        )
    }
}
