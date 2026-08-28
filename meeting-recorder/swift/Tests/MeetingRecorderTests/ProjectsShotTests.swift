import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Скретч-инструмент, а не проверка: рисует раздел «Проекты» в PNG, чтобы его
/// можно было положить рядом с макетом (Figma `projects`, 254:3400).
/// Пропускается, пока `PROJECTS_SHOT` не назовёт путь.
///
///     PROJECTS_SHOT=/tmp/projects.png swift test --filter ProjectsShot
///     PROJECTS_SHOT=/tmp/empty.png PROJECTS_SHOT_STATE=empty swift test --filter ProjectsShot
///     PROJECTS_SHOT=/tmp/new.png PROJECTS_SHOT_STATE=new swift test --filter ProjectsShot
///
/// Рисуется **вёрстка**, а не экран: настоящий `ProjectsPane` держится на
/// `AppState`, который в тестовом процессе не поднять. Ширина 649 — колонка
/// панели при рельсе на месте, ровно как в макете.
///
/// Живое окно для замеров не годится: под прозрачным фоном дизеринг рабочего
/// стола. Офскрин плоский и детерминированный.
final class ProjectsShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["PROJECTS_SHOT"] == nil,
            "PROJECTS_SHOT is not set — nothing to render into"
        )
        let output = ProcessInfo.processInfo.environment["PROJECTS_SHOT"]!
        let which = ProcessInfo.processInfo.environment["PROJECTS_SHOT_STATE"] ?? "list"

        let size = CGSize(width: 649, height: 640)
        let root = ProjectsBoard(state: which)
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
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

private struct ProjectsBoard: View {
    let state: String

    @State private var name = ""
    @State private var about = ""

    private let cards: [(String, String, String)] = [
        ("VK Музыка",
         "Объём Discovery: ограничили проработкой «хэппи-пэйтов», исключив обработку ошибок "
            + "и угловых случаев (нехватка средств, отсутствие адреса). Это сделает артефакты "
            + "понятнее без потери времени.",
         "Вчера · 12 встреч"),
        ("Менторство с Лёшей",
         "Переходим с ручной сборки HTML на использование генератора приложений в Swift для "
            + "новых и старых «прилок».",
         "2 дня назад · 2 встречи"),
        ("Переработка главной страницы",
         "Перераспределение фокусов: снять текущие задачи и упростить процесс, чтобы освободить "
            + "административный ресурс на новые проекты.",
         "Неделю назад · 26 встреч"),
        ("Дейлики", "", "Давно · 12 встреч"),
    ]

    var body: some View {
        switch state {
        case "empty":
            ProjectsEmptyState(create: {})
        case "new":
            ZStack {
                grid
                Tokens.Projects.Modal.scrim
                ProjectComposer(name: $name, about: $about, submit: {}, cancel: {})
            }
        default:
            grid
        }
    }

    private var grid: some View {
        PanePage("Проекты") {
            // Полосы с выпадашкой и «Новым проектом» здесь больше нет: кнопка
            // переехала в навбар, выбор порядка снят целиком.
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Tokens.Projects.gridGap),
                    count: Tokens.Projects.columns
                ),
                spacing: Tokens.Projects.gridGap
            ) {
                ForEach(cards, id: \.0) { card in
                    ProjectCard(
                        name: card.0, about: card.1, footer: card.2,
                        open: {},
                        menu: { EmptyView() }
                    )
                }
            }
        }
    }
}
