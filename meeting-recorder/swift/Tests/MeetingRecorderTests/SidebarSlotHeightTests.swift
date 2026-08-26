import XCTest
import SwiftUI
import AppKit
import PropellerPure
@testable import PropellerUI

/// Геометрия удаления строки: пепел рисуется поверх букв, которые он заменяет,
/// а слот под ним схлопывается от той высоты, которую строка занимала.
/// Разъедется что-то одно — список дёрнется в первый же кадр.
final class SidebarSlotHeightTests: XCTestCase {

    /// Ширина, которую рельс отдаёт строке: рельс минус поля списка.
    private var rowWidth: CGFloat {
        Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
    }

    private func measuredRowHeight(
        title: String,
        preview: String,
        state: SidebarRowState = SidebarRowState()
    ) -> CGFloat {
        let row = SidebarMeetingRowModel(
            id: "m1",
            meta: "17:30 · 45 мин",
            title: title,
            preview: preview,
            state: state
        )
        let hosting = NSHostingView(
            rootView: SidebarMeetingRow(row: row, action: {}).frame(width: rowWidth)
        )
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func rasterHeight(title: String, preview: String) -> CGFloat {
        AshField.rasterize(title: title, preview: preview, width: rowWidth, scale: 2)?.size.height ?? -1
    }

    /// Пепел встаёт ровно на буквы, а не рядом с ними. Растр и строка обязаны
    /// быть одной высоты — иначе поле частиц смещено на разницу.
    ///
    /// Проверяется на длинном названии: в рельсе оно теперь обрезается в одну
    /// строку, и высота растра обязана следовать за названной высотой ряда, а
    /// не за тем, во сколько строк текст лёг бы сам.
    func testTheAshRasterIsExactlyAsTallAsTheRowItStandsIn() {
        let title = "Разбор джобы про онбординг и первые семь дней"
        // Так его зовёт сама строка: описания в рельсе нет.
        let preview = ""
        let row = measuredRowHeight(title: title, preview: preview)
        let raster = rasterHeight(title: title, preview: preview)
        XCTAssertEqual(
            raster, row, accuracy: 1.0,
            "Растр пепла \(raster), строка \(row) — на столько пепел и промахнётся мимо букв."
        )
    }

    /// Удаление сначала уводит выделение на соседа и только потом зажигает
    /// пепел. Если выделенная строка выше невыделенной, строка теряет разницу
    /// скачком, и список под ней подпрыгивает, прежде чем поехать плавно.
    func testSelectionDoesNotChangeTheHeightOfARow() {
        let plain = measuredRowHeight(
            title: "Синк по найму", preview: "",
            state: SidebarRowState(isSelected: false)
        )
        let selected = measuredRowHeight(
            title: "Синк по найму", preview: "",
            state: SidebarRowState(isSelected: true)
        )
        XCTAssertEqual(
            plain, selected, accuracy: 0.5,
            "Выделенная строка \(selected), обычная \(plain) — на столько дёрнется список."
        )
    }
}
