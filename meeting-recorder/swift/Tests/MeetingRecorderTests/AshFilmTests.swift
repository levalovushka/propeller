import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Scratch tool: puts the rail in a **real** window on screen and lights the ash on
/// one row, so the deletion can be filmed with `screencapture` and measured frame by
/// frame. Rendering to a bitmap cannot show this — `cacheDisplay` draws the model
/// tree, and every animation here lives in the presentation layer.
///
/// Skipped unless `ASH_FILM` names which row to burn (`first` / `middle`):
///
///     screencapture -x -V 5 /tmp/film.mov &
///     ASH_FILM=first swift test --filter AshFilm
///
/// It prints the window's frame, which is what the measuring pass needs.
final class AshFilmTests: XCTestCase {

    @MainActor
    final class Burn: ObservableObject {
        @Published var dissolving: String?
    }

    private struct Harness: View {
        @ObservedObject var burn: Burn
        let model: SidebarModel

        var body: some View {
            PropellerSidebar(
                model: model,
                trafficLights: .drawn,
                dissolvingMeetingID: burn.dissolving,
                onToggle: {},
                onSearch: {}
            )
        }
    }

    @MainActor
    func testFilm() throws {
        let which = ProcessInfo.processInfo.environment["ASH_FILM"]
        try XCTSkipIf(which == nil, "ASH_FILM is not set — nothing to burn")

        // Three rows in today's group (no date of its own) and three under a date,
        // so «first in the list» and «one in the middle» are both available.
        func row(_ id: String, _ title: String, _ preview: String) -> SidebarMeetingRowModel {
            SidebarMeetingRowModel(
                id: id, meta: "18:0\(id) · 40 мин", title: title, preview: preview, state: .rest
            )
        }
        let model = SidebarModel(
            nav: [SidebarNavItem(id: "new", symbol: SidebarNavItem.propellerMarkSymbol, title: "Новая запись")],
            groups: [
                SidebarMeetingGroup(id: "today", header: nil, rows: [
                    row("1", "Первая в списке.", "Её и жжём в одном из прогонов"),
                    row("2", "Вторая.", "Остаётся на месте и служит меткой"),
                    row("3", "Третья.", "Тоже остаётся"),
                ]),
                SidebarMeetingGroup(id: "yst", header: "Вчера, 7 августа", rows: [
                    row("4", "Четвёртая.", "Под датой, середина списка"),
                    row("5", "Пятая.", "Метка ниже места удаления"),
                    row("6", "Шестая.", "И ещё одна метка"),
                ]),
            ]
        )

        let burn = Burn()
        let size = CGSize(width: Tokens.Sidebar.width, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.level = .floating
        window.contentView = NSHostingView(rootView: Harness(burn: burn, model: model))
        // A fixed corner, so the measuring pass needs no lookup.
        window.setFrameOrigin(NSPoint(x: 100, y: 200))
        window.orderFrontRegardless()
        let frame = window.frame
        print("ASH_FILM window: origin \(Int(frame.minX)),\(Int(frame.minY)) size \(Int(frame.width))x\(Int(frame.height))")
        print("ASH_FILM screen height: \(Int(NSScreen.main?.frame.height ?? 0))")

        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        print("ASH_FILM ignite at \(Date().timeIntervalSince1970)")
        burn.dissolving = which == "first" ? "1" : "5"
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        window.orderOut(nil)
    }
}
