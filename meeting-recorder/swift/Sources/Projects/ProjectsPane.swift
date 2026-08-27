import SwiftUI
import PropellerUI
import PropellerPure

/// Раздел «Проекты», как его видит человек — Figma `projects` (254:3400).
///
/// Вёрстка живёт в `PropellerUI/ProjectsKit.swift`; здесь только то, что читает
/// и пишет `AppState`.
///
/// Порядок сортировки не запоминается между запусками — как и у настроек,
/// раздел открывается в том виде, который человек может предсказать, не помня
/// прошлого сеанса. Если окажется, что один порядок выбирают устойчиво, он
/// станет умолчанием, а не памятью.
struct ProjectsPane: View {
    @ObservedObject var state: AppState

    @State private var order: ProjectOrder = .entry

    private var cards: [ProjectSummary] { state.projectSummaries.ordered(by: order) }

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
        PanePage("Проекты", trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Tokens.Projects.barGap) {
                HStack(spacing: Tokens.Projects.cardGap) {
                    ProjectsSortMenu(selection: $order)
                    Spacer(minLength: 0)
                    ProjectsActionButton("Новый проект") { state.composeProject() }
                }
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
    }

    private func open(_ project: Project) {
        state.openProject(project.id)
    }
}
