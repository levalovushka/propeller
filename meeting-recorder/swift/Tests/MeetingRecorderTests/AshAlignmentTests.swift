import XCTest
import SwiftUI
import AppKit
import PropellerPure
@testable import PropellerUI

/// «Буквы не подпрыгивают в момент, когда строка становится пеплом.»
///
/// Пепел — это текстура: строка один раз растеризуется через AppKit и дальше живёт
/// частицами. Настоящую строку рисует SwiftUI. Две системы ставят первую строку
/// текста по-своему, и если разойтись хоть на пару точек, в кадр поджига буквы
/// прыгают — а прыгают они на глазах, потому что ровно в этот кадр настоящая строка
/// становится прозрачной и её место занимает растр.
///
/// Проверяется не «правильное» число, а совпадение: где начинается тушь у одной,
/// там же обязана начинаться у другой.
final class AshAlignmentTests: XCTestCase {

    /// Ширина строки в рельсе — от неё зависят переносы, а значит и высота.
    private var rowWidth: CGFloat {
        Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
    }

    private let title = "Агентный дизайн."
    private let preview = "Выравнивание панели инструментов, удаление кнопок Enter из текста"

    @MainActor
    func testТушьПеплаНачинаетсяТамЖеГдеТушьСтроки() throws {
        let scale: CGFloat = 2

        let shot = try XCTUnwrap(
            AshField.rasterize(title: title, preview: preview, width: rowWidth, scale: scale),
            "растеризатор пепла ничего не отдал"
        )
        let ashTop = try XCTUnwrap(firstInkRow(in: shot.cgImage), "в растре нет туши") / scale

        let row = SidebarMeetingRow(
            row: SidebarMeetingRowModel(
                id: "1", meta: "", title: title, preview: preview, state: .rest
            ),
            action: {}
        )
        let rowTop = try XCTUnwrap(firstInkRow(inRendered: row), "в строке нет туши") / scale

        // Половина точки — предел, ниже которого на 2× не остаётся ни одного
        // пикселя разницы.
        XCTAssertEqual(
            ashTop, rowTop, accuracy: 0.5,
            "пепел начинает рисовать буквы на \(rowTop - ashTop) pt выше строки, "
                + "и на этот скачок буквы прыгают в кадр поджига"
        )
    }

    // MARK: - Измерение

    /// Первая строка пикселей, в которой есть хоть что-то непрозрачное.
    private func firstInkRow(in image: CGImage) -> CGFloat? {
        let rep = NSBitmapImageRep(cgImage: image)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.alphaComponent > 0.3 { return CGFloat(y) }
            }
        }
        return nil
    }

    /// То же самое, но для вида: рисуем его на прозрачном фоне и ищем тушь.
    @MainActor
    private func firstInkRow(inRendered view: some View) -> CGFloat? {
        let hosting = NSHostingView(rootView: view.frame(width: rowWidth))
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layout()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // Тушь строки — светлая на прозрачном: `alpha` ловит и её, и
                // возможную подложку, поэтому спрашиваем ещё и яркость.
                if c.alphaComponent > 0.3, c.brightnessComponent > 0.3 { return CGFloat(y) }
            }
        }
        return nil
    }
}
