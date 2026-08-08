import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Scratch tool: renders the ⌥Tab panel in three situations so they can be
/// compared with the comps. Skipped unless `SWITCHER_SHOT` names an output path:
///
///     SWITCHER_SHOT=/tmp/switcher.png swift test --filter TempSwitcherShot
final class TempSwitcherShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        let output = ProcessInfo.processInfo.environment["SWITCHER_SHOT"]
        try XCTSkipIf(output == nil, "SWITCHER_SHOT is not set")

        let titles: [(String, String, SidebarRowState)] = [
            ("PG x VK Музыка.", "Транскрибируем…", SidebarRowState(activity: .processing)),
            ("Воркшоп по VK Музыке.", "Обсудили этапы, выявили препятствия, наметили следующие шаги.", SidebarRowState()),
            ("Тактика | Лиды.", "Обсудили ошибки и предложили пути их устранения.", SidebarRowState()),
            ("ГПН Портал | Внутренний воркшоп.", "Определили задачи, приоритеты и сроки выполнения.", SidebarRowState()),
            ("Агентный дизайн с Женей.", "Отказ от дизайн-системы, сетап из макетов и правил.", SidebarRowState()),
            ("VK Камуфляжные приложения.", "Единые токены Video и Музыки.", SidebarRowState()),
            ("Пятничный созвон.", "Ничего важного.", SidebarRowState()),
        ]
        let rows = titles.enumerated().map { index, t in
            SidebarMeetingRowModel(
                id: "m\(index)", meta: "18:0\(index) · 40 мин",
                title: t.0, preview: t.1, state: t.2
            )
        }

        func panel(_ rows: [SidebarMeetingRowModel], current: Int) -> some View {
            let walk = MeetingSwitch(order: rows.map(\.id), startingAt: rows[current].id)!
            return VStack(spacing: 8) {
                MeetingSwitcherPanel(
                    rows: rows, currentID: walk.currentID, anchorID: walk.anchorID
                )
            }
        }

        let root = HStack(alignment: .top, spacing: 24) {
            panel(rows, current: 1)                        // second in a long list
            panel(rows, current: rows.count - 1)           // the last one — offset clamps
            panel(Array(rows.prefix(2)), current: 1)       // two meetings only
        }
        .padding(24)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .environment(\.colorScheme, .dark)

        let size = CGSize(width: 1050, height: 420)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output!))
    }
}
