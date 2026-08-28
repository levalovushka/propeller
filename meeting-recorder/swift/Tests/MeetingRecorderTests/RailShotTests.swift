import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// `XCTSkipUnless` with a value: skips the test when the variable is absent, and
/// hands it over when it is there.
private func XCTSkipIfNil(_ value: String?) throws -> String {
    try XCTSkipIf(value == nil, "RAIL_SHOT is not set — nothing to render into")
    return value!
}

/// Scratch tool: renders the rail to a PNG so it can be compared with the comps.
/// Not an assertion about anything — it is skipped unless `RAIL_SHOT` names an
/// output path:
///
///     RAIL_SHOT=/tmp/rail.png swift test --filter RailShot
///
/// It used to run on every `swift test` and take the whole suite down with it:
/// `NSApp` is nil in the xctest process, and the line that set its appearance
/// force-unwrapped it. Everything after this suite — seventeen cases — never ran.
final class RailShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        let output = try XCTSkipIfNil(ProcessInfo.processInfo.environment["RAIL_SHOT"])
        let model = SidebarModel(
            nav: [
                SidebarNavItem(id: "new", symbol: SidebarNavItem.propellerMarkSymbol, title: "Новая запись"),
                // Под курсором — иначе плюса в кадре не будет: в покое он
                // прозрачен. Две наведённые строки разом в приложении
                // невозможны, но это сверочный лист, а не снимок экрана.
                SidebarNavItem(
                    id: "projects", symbol: "folder.fill", title: "Проекты",
                    quickAction: .init(symbol: "plus", title: "Новый проект"),
                    isHovered: true
                ),
                SidebarNavItem(id: "settings", symbol: "gearshape.fill", title: "Настройки", isHovered: true),
            ],
            body: .archive(groups: [
                // Все четыре движущиеся иконки в одном кадре: только рядом
                // видно, что они различимы, а ради этого они и заведены.
                SidebarMeetingGroup(id: "g0", header: nil, rows: [
                    SidebarMeetingRowModel(
                        id: "0", meta: "19:30",
                        title: "Идёт прямо сейчас",
                        preview: "",
                        state: SidebarRowState(activity: .recording)
                    ),
                    SidebarMeetingRowModel(
                        id: "1", meta: "18:01 · 1 ч 24 мин",
                        title: "Агентный дизайн с Женей",
                        preview: "",
                        state: SidebarRowState(isSelected: true, activity: .processing)
                    ),
                    SidebarMeetingRowModel(
                        id: "2", meta: "16:22 · 34 мин",
                        title: "VK Камуфляжные приложения, длинное название на обрезку",
                        preview: "",
                        state: SidebarRowState(isHovered: true, activity: .queued)
                    ),
                    SidebarMeetingRowModel(
                        id: "3", meta: "15:00 · 56 мин",
                        title: "PG x VK Музыка",
                        preview: "",
                        state: SidebarRowState(activity: .stalled)
                    ),
                ]),
                SidebarMeetingGroup(id: "g1", header: "31 июля", rows: [
                    SidebarMeetingRowModel(
                        id: "5", meta: "12:00 · 3 мин",
                        title: "Никто ничего не сказал",
                        preview: "",
                        state: SidebarRowState(activity: .rests)
                    ),
                    SidebarMeetingRowModel(
                        id: "4", meta: "11:00 · 21 мин",
                        title: "Один в своём дне",
                        preview: "",
                        // Hovered on purpose: deletion is done from the row's own
                        // menu, so the plate under the letters is there — and it is
                        // the only part of the ash a test process can see, Metal
                        // being absent. Its top edge is where the flakes are.
                        state: SidebarRowState(isHovered: true)
                    ),
                ]),
            ])
        )

        // No `NSApp` here: there is no NSApplication in a test process, and the
        // window below carries the appearance anyway.
        let size = CGSize(width: Tokens.Sidebar.width, height: 560)
        let root = ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08)
            PropellerSidebar(
                model: model, trafficLights: .drawn,
                onNavQuickAction: { _ in },
                // Set to «4» to photograph the group that is on its way out: its
                // date and its gap must already be gone.
                dissolvingMeetingID: ProcessInfo.processInfo.environment["RAIL_SHOT_DISSOLVING"],
                onToggle: {}, onSearch: {}
            )
        }
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // How far into any animation the shot is taken. 0.3 by default — long
        // enough for one-shot arrivals to have landed; `RAIL_SHOT_SETTLE` catches an
        // earlier frame, which is how the ash is compared with the letters it stands
        // in for.
        let settle = Double(ProcessInfo.processInfo.environment["RAIL_SHOT_SETTLE"] ?? "0.3") ?? 0.3
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
    }
}
