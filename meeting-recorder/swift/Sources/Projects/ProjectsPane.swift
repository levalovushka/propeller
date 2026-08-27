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
    @State private var deleting: Project?

    private var cards: [ProjectSummary] { state.projectSummaries.ordered(by: order) }

    var body: some View {
        Group {
            if cards.isEmpty {
                ProjectsEmptyState(create: { state.composeProject() })
            } else {
                page
            }
        }
        .confirmationDialog(
            deleting.map { "Удалить проект «\($0.name)»?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить проект", role: .destructive) {
                if let id = deleting?.id { state.deleteProject(id) }
                deleting = nil
            }
            Button("Отменить", role: .cancel) { deleting = nil }
        } message: {
            Text("Встречи останутся на месте — с них снимется метка.")
        }
        .onAppear { state.reloadProjects() }
    }

    private var page: some View {
        PanePage("Проекты") {
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
                            open: { open(card.project) },
                            menu: { menu(for: card.project) }
                        )
                    }
                }
            }
        }
    }

    /// Меню карточки — системное. Макет рисует свою плиту (268:12170), но
    /// нарисованное меню теряет клавиатуру и доступность; то же решение уже
    /// принято для `SettingsMenu`.
    ///
    /// «Закрепить» из макета здесь нет: закрепления в спеке проектов не
    /// существует, порядок задаёт сортировка. «Добавить записи» уедет на экран
    /// проекта, где живёт список встреч.
    private func menu(for project: Project) -> some View {
        MinimalIconMenu(
            systemName: "ellipsis",
            iconSize: Tokens.Projects.Typo.action.size,
            help: "Действия с проектом"
        ) {
            Button("Редактировать") { state.composeProject(editing: project) }
            Divider()
            Button(project.archived ? "Вернуть из архива" : "В архив") {
                state.setProject(project.id, archived: !project.archived)
            }
            Divider()
            Button("Удалить проект", role: .destructive) { deleting = project }
        }
    }

    private func open(_ project: Project) {
        // Экрана проекта ещё нет (шаг 3 плана). Пока карточка открывает правку —
        // это единственное, что за ней сегодня стоит, и «нажал, ничего не
        // произошло» здесь было бы хуже.
        state.composeProject(editing: project)
    }
}
