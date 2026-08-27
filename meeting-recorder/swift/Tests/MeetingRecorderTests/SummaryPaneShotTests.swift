import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Скретч-инструмент, а не проверка: рисует панель встречи в PNG, чтобы её
/// можно было положить рядом с макетом 312:11129. Пропускается, пока
/// `SUMMARY_SHOT` не назовёт путь.
///
///     SUMMARY_SHOT=/tmp/summary.png swift test --filter SummaryPaneShot
///     SUMMARY_SHOT=/tmp/wide.png SUMMARY_SHOT_WIDTH=1400 swift test --filter SummaryPaneShot
///
/// Живое окно для замеров не годится — под прозрачным фоном дизеринг рабочего
/// стола, — а `Sources/` тестам недоступен. Здесь рисуется `MeetingPaneBody`
/// на фикстуре, то есть ровно то, что видно в приложении справа от рельса.
final class SummaryPaneShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SUMMARY_SHOT"] == nil,
            "SUMMARY_SHOT is not set — nothing to render into"
        )
        let output = ProcessInfo.processInfo.environment["SUMMARY_SHOT"]!

        // Ширина — ручка, а не константа: на мере макета угол блока и угол окна
        // совпадают, и снимок в 649 не может показать, к чему прижаты кнопки.
        //
        //     SUMMARY_SHOT=/tmp/wide.png SUMMARY_SHOT_WIDTH=1400 swift test --filter SummaryPaneShot
        var width = Tokens.Pane.paneMeasure
        if let raw = ProcessInfo.processInfo.environment["SUMMARY_SHOT_WIDTH"],
           let asked = Double(raw) {
            width = CGFloat(asked)
        }
        let size = CGSize(width: width, height: 760)
        let root = MeetingPaneBody(
            identity: .init(
                meetingID: "shot",
                title: "Базированный утренник",
                onRename: { _, _ in }
            ),
            meta: .init(
                date: Date(timeIntervalSince1970: 1_787_412_600),
                // Шесть рядов, а не число: чип показывает длину списка, и снимок
                // должен ломаться, если состав перестанет её давать.
                people: .init(rows: Self.roster)
            ),
            share: .init("Поделиться") {},
            summary: Self.summary
        )
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
        .background(Tokens.Paint.Bg.page)

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

    /// Тот же конспект, что в макете: лид, «Решения», «Задачи».
    /// Состав снимка — шесть имён из макета 312:11129.
    private static let roster: [MeetingRoster.Row] = [
        .init(name: "Левон", origin: .owner, label: "Левон"),
        .init(name: "Илья Федоренко", origin: .call, label: "Илья Федоренко"),
        .init(name: "Костя Замуренко", origin: .call, label: "Костя Замуренко"),
        .init(name: "Женя Яровой", origin: .call, label: "Женя Яровой"),
        .init(name: "Арина Солдатенкова", origin: .call, label: nil),
        .init(name: "Полина Кременец", origin: .spoken, label: "Полина Кременец"),
    ]

    private static let summary = SummaryDocument.parse(markdown: """
    ## Итог
    На встрече обсуждали переработку дизайна главной страницы приложения. \
    Костя Замуренко предложил убрать «надуманные» элементы (барабан) и \
    заменить их плотной структурой контента для быстрого скроллинга.

    ## Решения
    - Отказались от идеи зацикленного «барабана» как центральной фигуры \
    главной страницы. Илона Саркисова настояла, что он не имеет логического \
    обоснования за пределами главного экрана и выглядит топорно.
    - Решили использовать плотную сетку из чипсов для отображения кластеров \
    артистов, альбомов или сценариев в верхней части страницы без \
    горизонтального скролла.
    - Запустить цикл пресейла в первой половине недели силами Полины, Ильяса \
    и Льва; Лёву включить как менеджера по координации, а Полина берет на \
    себя верификацию и доработки во вторую половину.

    ## Задачи
    - **Даня Москаленко** — уточнить у Арины детали оплаты и включены ли в \
    смету услуги по подключению генеративщиков.
    - Подготовить примерные визуальные материалы для анимаций перед финальным \
    согласованием концепции главной страницы со стороны клиента.
    """)
}
