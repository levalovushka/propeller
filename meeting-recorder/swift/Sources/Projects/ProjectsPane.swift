import SwiftUI
import PropellerUI
import PropellerPure

/// Раздел «Проекты», как его видит человек — Figma `projects` (254:3400).
///
/// Вёрстка живёт в `PropellerUI/ProjectsKit.swift`; здесь только то, что читает
/// и пишет `AppState`.
///
/// Порядок сортировки не выбирается вовсе: карточки стоят от свежих к старым,
/// архивные внизу (`ProjectOrder.entry`). Выпадашка стояла и снята вместе со
/// всей полосой — за вторым порядком не было ничего, кроме макета.
struct ProjectsPane: View {
    @ObservedObject var state: AppState

    /// Порядок один и не выбирается. Полоса с выпадашкой и «Новым проектом»
    /// снята 2026-08-28 решением владельца: кнопка переехала в навбар, а выбор
    /// порядка ушёл вместе с ней — за ним не стояло ничего, кроме макета.
    /// Цена названа вслух: `ProjectOrder.alphabetical` двери в приложении
    /// больше не имеет.
    private var cards: [ProjectSummary] { state.projectSummaries.ordered(by: .entry) }

    var body: some View {
        Group {
            if cards.isEmpty {
                ProjectsEmptyState(create: { state.composeProject() })
            } else {
                page
            }
        }
        .onAppear { state.reloadProjects() }
    }

    private var page: some View {
        PanePage("Проекты") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Tokens.Projects.gridGap),
                    count: Tokens.Projects.columns
                ),
                spacing: Tokens.Projects.gridGap
            ) {
                ForEach(cards) { card in
                    ProjectCard(
                        name: card.project.name,
                        about: card.project.about,
                        footer: ProjectCardText.footer(meetings: card.meetings, last: card.last),
                        dimmed: card.project.archived,
                        open: { open(card.project) },
                        menu: { ProjectActionsMenu(state: state, project: card.project) }
                    )
                }
            }
        }
    }

    private func open(_ project: Project) {
        state.openProject(project.id)
    }
}
