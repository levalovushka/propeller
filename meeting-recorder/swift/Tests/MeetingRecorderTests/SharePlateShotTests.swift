import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Скретч-инструмент: рисует обе плиты публикации рядом, чтобы их можно было
/// положить рядом с макетом `summary/share-link` (298:26607, 298:26275).
///
///     SHARE_SHOT=/tmp/share.png swift test --filter SharePlateShot
final class SharePlateShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SHARE_SHOT"] == nil,
            "SHARE_SHOT is not set — nothing to render into"
        )
        let output = ProcessInfo.processInfo.environment["SHARE_SHOT"]!

        let size = CGSize(width: 840, height: 520)
        let root = HStack(alignment: .top, spacing: 40) {
            SharePlate(
                mode: .compose,
                lifetime: .constant("month"),
                lifetimes: [.init(id: "week", title: "Неделя"), .init(id: "month", title: "Месяц")],
                preview: Self.preview
            )
            SharePlate(
                mode: .published(URL(string: "https://propeller.report/s/2333id1234344#k=abc")!),
                lifetime: .constant("month"),
                lifetimes: [.init(id: "week", title: "Неделя"), .init(id: "month", title: "Месяц")],
                preview: Self.preview
            )
        }
        .padding(40)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .background(Tokens.Paint.Bg.page)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
    }

    private static let preview = SharedSummaryPreview.Model(
        title: "Базированный утренник",
        meta: "22 авг, 16:30 · 6 человек",
        lines: [
            "На встрече обсуждали переработку дизайна главной страницы приложения.",
            "Отказались от идеи зацикленного «барабана» как центральной фигуры.",
            "Решили использовать плотную сетку из чипсов для кластеров артистов.",
        ]
    )
}
