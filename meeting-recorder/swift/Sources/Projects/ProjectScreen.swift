import SwiftUI
import PropellerUI
import PropellerPure

/// Экран одного проекта — Figma `project/meetings-tab` (256:6954) и
/// `project/participants-tab` (256:7467).
///
/// Две вкладки из четырёх: «Решения» и «Задачи» приедут с разбором атомов
/// (`plan-projects.md` §12, шаг 4). Вкладка живёт в маршруте (`PaneRoute`), а не
/// в `@State`, — иначе её нельзя было бы ни снять галереей, ни открыть ссылкой.
/// Смены вкладки при этом **не видит** `MainView.paneSubject`: он нарочно
/// отбрасывает её, чтобы клик по вкладке не проигрывал затухание всей панели.
struct ProjectScreen: View {
    @ObservedObject var state: AppState
    let project: Project
    let tab: ProjectTab

    private var meetings: [RecordingEntry] { state.meetings(of: project.id) }

    var body: some View {
        PanePage(project.name, titleGap: Tokens.Projects.Screen.headerGap, trailing: {
            ProjectActionsMenu(state: state, project: project)
        }) {
            VStack(alignment: .leading, spacing: Tokens.Projects.Screen.tabsGap) {
                header
                VStack(alignment: .leading, spacing: Tokens.Projects.Screen.listGap) {
                    ProjectTabBar(selection: Binding(
                        get: { tab },
                        set: { state.selectProjectTab($0) }
                    ))
                    switch tab {
                    case .meetings:     meetingList
                    case .participants: participantList
                    }
                }
            }
        }
    }

    /// Имя вынесено в `PanePage`, поэтому здесь только описание и подпись:
    /// заголовок страницы и имя проекта — это одна и та же строка, и рисовать
    /// её дважды значило бы разъехаться на первой же правке отступов.
    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.Screen.aboutGap) {
            if !project.about.isEmpty {
                Text(project.about)
                    .typo(Tokens.Projects.Typo.screenBody)
                    .foregroundStyle(Tokens.Projects.quiet)
                    .lineLimit(Tokens.Projects.Screen.aboutLines)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Text(ProjectCardText.footer(
                meetings: meetings.count, last: meetings.first?.date
            ))
            .typo(Tokens.Projects.Typo.body)
            .foregroundStyle(Tokens.Projects.quiet)
        }
    }

    @ViewBuilder
    private var meetingList: some View {
        if meetings.isEmpty {
            emptyTab("Пока ни одной встречи",
                     "Поставьте проекту метку на встрече — и она появится здесь.")
        } else {
            rows(meetings) { entry in
                ProjectMeetingRow(
                    meta: ProjectCardText.meetingLine(date: entry.date, duration: entry.duration),
                    subtitle: entry.title,
                    open: { state.selectRecording(entry) }
                )
            }
        }
    }

    @ViewBuilder
    private var participantList: some View {
        let people = state.roster(of: project.id)
        if people.isEmpty {
            emptyTab(
                "Пока некого показать",
                // Не «людей не было», а «архив их не знает»: диаризация называет
                // по имени одного, остальные остаются `Speaker N`, а календарь
                // есть не у каждой встречи.
                "Имена приходят из подписей расшифровки и из приглашённых в календаре."
            )
        } else {
            rows(people) { person in
                ProjectPersonRow(name: person.name, subtitle: ProjectRoster.subtitle(for: person))
            }
        }
    }

    /// Список с волосяными линиями **между** строками. Тот же порядок, что у
    /// карточки настроек: разделитель после каждой строки оставил бы линию под
    /// последней, висящую над пустотой.
    private func rows<Item: Identifiable, Row: View>(
        _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ProjectRowDivider() }
                row(item)
            }
        }
    }

    private func emptyTab(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.Screen.rowLineGap) {
            Text(title)
                .typo(Tokens.Projects.Typo.title)
                .foregroundStyle(Tokens.Projects.title)
            Text(explanation)
                .typo(Tokens.Projects.Typo.body)
                .foregroundStyle(Tokens.Projects.quiet)
        }
        .padding(.vertical, Tokens.Projects.Screen.rowVPadding)
        .padding(.horizontal, Tokens.Projects.Screen.meetingInset)
    }
}
