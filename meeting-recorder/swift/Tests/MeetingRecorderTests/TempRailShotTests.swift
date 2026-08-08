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
///     RAIL_SHOT=/tmp/rail.png swift test --filter TempRailShot
///
/// It used to run on every `swift test` and take the whole suite down with it:
/// `NSApp` is nil in the xctest process, and the line that set its appearance
/// force-unwrapped it. Everything after this suite — seventeen cases — never ran.
final class TempRailShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        let output = try XCTSkipIfNil(ProcessInfo.processInfo.environment["RAIL_SHOT"])
        let model = SidebarModel(
            nav: [
                SidebarNavItem(id: "new", symbol: SidebarNavItem.propellerMarkSymbol, title: "Новая запись"),
                SidebarNavItem(id: "settings", symbol: "gearshape.fill", title: "Настройки", isHovered: true),
                SidebarNavItem(id: "bug", symbol: "ladybug.fill", title: "Сообщить о проблеме", hint: .opensBrowser),
            ],
            groups: [
                SidebarMeetingGroup(id: "g0", header: "Вчера, 3 августа", rows: [
                    SidebarMeetingRowModel(
                        id: "1", meta: "18:01 · 1 ч 24 мин",
                        title: "Агентный дизайн с Женей.",
                        preview: "Отказ от дизайн-системы, сетап из макетов и правил",
                        state: SidebarRowState(isSelected: true)
                    ),
                    SidebarMeetingRowModel(
                        id: "2", meta: "16:22 · 34 мин",
                        title: "VK Камуфляжные приложения.",
                        preview: "Единые токены Video и Музыки, бриф: overview и design-fact",
                        state: SidebarRowState(isHovered: true)
                    ),
                    SidebarMeetingRowModel(
                        id: "3", meta: "15:00 · 56 мин",
                        title: "PG x VK Музыка.",
                        preview: "Пересборка главной под Rich Text, VK Микс уступает место кластерам",
                        state: .rest
                    ),
                ]),
                SidebarMeetingGroup(id: "g1", header: "Четверг, 31 июля", rows: [
                    SidebarMeetingRowModel(
                        id: "4", meta: "11:00 · 21 мин",
                        title: "Один в своём дне.",
                        preview: "Единственная встреча под этой датой",
                        state: .rest
                    ),
                ]),
            ]
        )

        // No `NSApp` here: there is no NSApplication in a test process, and the
        // window below carries the appearance anyway.
        let size = CGSize(width: Tokens.Sidebar.width, height: 560)
        let root = ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08)
            PropellerSidebar(
                model: model, trafficLights: .drawn,
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
    }
}
