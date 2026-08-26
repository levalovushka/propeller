import XCTest
import SwiftUI
import AppKit
import PropellerPure
@testable import PropellerUI

/// Экран настроек в точках — Figma `settings/general` (254:1339).
///
/// Числа здесь сняты с экспорта макета, а не с глаза, и держат ровно то, что
/// глазом не проверить: где начинается карточка, какой она ширины и на сколько
/// её отступы расходятся с заявленными. Один раз всё это уже разъехалось —
/// потолок ширины стоял поверх отступов, и на ширине макета колонка
/// центрировалась, сдвигая карточку на 4,5 pt.
final class SettingsLayoutTests: XCTestCase {

    /// Ширина панели в макете: 913 всего, 264 из них — рельс.
    private let paneWidth: CGFloat = 649

    @MainActor
    private func render(_ view: some View, width: CGFloat, height: CGFloat) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// Одна карточка с одной ячейкой — минимум, на котором видны все отступы.
    private var page: some View {
        SettingsPage("Основные") {
            SettingsCard {
                SettingsCell("Ваше имя", subtitle: "Для подписи в саммари")
            }
        }
        .background(Color.black)
    }

    /// Первый непрозрачный пиксель карточки в столбце `x`, сверху.
    private func firstCardRow(_ rep: NSBitmapImageRep, x: Int) -> CGFloat? {
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.03 { return CGFloat(y) / CGFloat(rep.pixelsHigh) }
        }
        return nil
    }

    @MainActor
    func testTheCardSpansTheWidthTheCompsGiveIt() {
        let rep = render(page, width: paneWidth, height: 300)
        let scale = CGFloat(rep.pixelsWide) / paneWidth
        // Полоса заведомо внутри карточки по вертикали: заголовок 24, отступ 28
        // сверху, зазор 20 — карточка начинается за 70-й точкой.
        let y = Int(90 * scale)
        var left: CGFloat = -1, right: CGFloat = -1
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.03 {
                if left < 0 { left = CGFloat(x) / scale }
                right = CGFloat(x + 1) / scale
            }
        }
        XCTAssertEqual(left, Tokens.Settings.pageHPadding, accuracy: 0.6,
                       "карточка начинается на \(left), а поле страницы — \(Tokens.Settings.pageHPadding)")
        XCTAssertEqual(right, paneWidth - Tokens.Settings.pageHPadding, accuracy: 0.6,
                       "правый край карточки \(right) против \(paneWidth - Tokens.Settings.pageHPadding)")
    }

    @MainActor
    func testTheFirstCardStartsWhereTheTitleAndTheGapLeaveIt() {
        // 28 поля + 24 заголовок + 20 зазор. Число проверяет три токена сразу, и
        // именно оно ломается, когда заголовок отдаёт бокс по шрифту, а не по
        // макету: SF на 17 pt рисует 23, и карточка уезжает на точку вверх.
        let expected = Tokens.Settings.pageVPadding
            + Tokens.Settings.Typo.page.lineHeight
            + Tokens.Settings.blockGap
        let rep = render(page, width: paneWidth, height: 300)
        let scale = CGFloat(rep.pixelsHigh) / 300
        var top: CGFloat = -1
        // Середина, а не край: слева над карточкой стоит сам заголовок раздела
        // (столбец поймал бы его букву), а у края верхняя кромка лежит на дуге
        // скругления и отдаёт полточки лишку.
        let x = Int((paneWidth / 2) * scale)
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.03 { top = CGFloat(y) / scale; break }
        }
        XCTAssertEqual(top, expected, accuracy: 0.6,
                       "карточка на \(top), а по токенам должна на \(expected)")
    }

    @MainActor
    func testACellIsAsTallAsItsPaddingsAndItsTwoLines() {
        // Ячейка = отступ + заголовок + зазор + подпись + отступ. Подпись 12/15,
        // а не 12/14 макета: 14 — это сырые метрики SF, округлённые вниз, и
        // просить их значит просить бокс теснее начертания.
        let expected = Tokens.Settings.cellVPadding * 2
            + Tokens.Settings.Typo.title.lineHeight
            + Tokens.Settings.cellLineGap
            + Tokens.Settings.Typo.subtitle.lineHeight
        let hosting = NSHostingView(
            rootView: SettingsCell("Ваше имя", subtitle: "Для подписи в саммари")
                .frame(width: 577 - Tokens.Settings.cardHPadding * 2)
        )
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.height, expected, accuracy: 0.6,
                       "ячейка \(hosting.fittingSize.height) против \(expected)")
    }
}
