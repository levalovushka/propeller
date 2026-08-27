import SwiftUI
import PropellerUI
import PropellerPure

/// Экран одного проекта — Figma `project/meetings-tab` (256:6954) и
/// `project/participants-tab` (256:7467).
///
/// Вкладка живёт в маршруте (`PaneRoute`), а не в `@State`: иначе её нельзя ни
/// снять галереей, ни открыть ссылкой. Смены вкладки при этом **не видит**
/// `MainView.paneSubject` — он нарочно отбрасывает её, чтобы клик по вкладке не
/// проигрывал затухание всей панели.
///
/// Оба списка — `SettingsCard`: в макете это та же карточка, что у настроек
/// (заливка 7 %, скругление 14, волосяная линия между строками), и второй такой
/// же в приложении заводить нечего.
struct ProjectScreen: View {
    @ObservedObject var state: AppState
    let project: Project
    let tab: ProjectTab

    private var meetings: [RecordingEntry] { state.meetings(of: project.id) }

    var body: some View {
        PanePage(project.name, titleGap: Tokens.Projects.Screen.headerGap, trailing: {
            ProjectActionsMenu(state: state, project: project,
                               iconSize: Tokens.Projects.Typo.title.size)
        }) {
            VStack(alignment: .leading, spacing: Tokens.Projects.Screen.tabsGap) {
                header
                VStack(alignment: .leading, spacing: Tokens.Projects.Screen.listGap) {
                    ProjectTabBar(selection: Binding(
                        get: { tab },
                        set: { state.selectProjectTab($0) }
                    ))
                    switch tab {
                    case .decisions, .tasks: atomList
                    case .meetings:          meetingList
                    case .participants:      participantList
                    }
                }
            }
        }
    }

    // MARK: - Шапка

    /// Имя вынесено в `PanePage`: заголовок страницы и имя проекта — одна и та
    /// же строка, и рисовать её дважды значило бы разъехаться на первой же
    /// правке отступов.
    @ViewBuilder
    private var header: some View {
        if !project.about.isEmpty {
            // «Показать больше» здесь стояло и снято 2026-08-27 решением
            // владельца. Кнопка стояла всегда, пока описание есть, — а описание
            // почти всегда короче трёх строк, и нажатие тогда не делало ничего.
            // Кнопка, у которой в обычном случае нет последствий, хуже, чем
            // обрезанная третья строка (`design/no-dead-ends.md`).
            Text(project.about)
                .typo(Tokens.Projects.Typo.screenBody)
                .foregroundStyle(Tokens.Projects.title)
                .lineLimit(Tokens.Projects.Screen.aboutLines)
                .frame(maxWidth: Tokens.Projects.Screen.aboutMeasure, alignment: .topLeading)
        }
    }

    // MARK: - Решения и задачи

    /// Пункты, сгруппированные по встрече: пункт принадлежит встрече, а не
    /// проекту, и правка отсюда меняет документ той встречи, где он прозвучал
    /// (`plan-projects.md` §4.6). Заголовок группы про это и говорит.
    @ViewBuilder
    private var atomList: some View {
        if let section = tab.recapSection {
            let groups = state.atoms(of: project.id, section: section)
            if groups.isEmpty {
                emptyTab(
                    tab == .tasks ? "Пока ни одной задачи" : "Пока ни одного решения",
                    "Они появятся сами: конспект каждой встречи проекта отдаёт сюда свой раздел «\(section)»."
                )
            } else {
                VStack(alignment: .leading, spacing: Tokens.Projects.Atom.groupGap) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: Tokens.Projects.Atom.groupHeaderGap) {
                            ProjectAtomGroupHeader(
                                title: group.meeting.title,
                                when: SidebarDayGrouping.day(for: group.meeting.date).header
                                    ?? ProjectCardText.recency(of: group.meeting.date)
                            )
                            ProjectAtomCard {
                                ForEach(group.items) { item in
                                    row(item, of: group.meeting, section: section)
                                }
                                ProjectAtomAddRow { body in
                                    state.appendAtom(
                                        to: group.meeting, section: section, body: body
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Ответственный есть только у задачи.
    ///
    /// Решение не поручают — его принимают, и в макете решений (297:25206) чипа
    /// нет ни у одной строки. Но модель регулярно пишет решение в форме задачи
    /// («**Vlad** — зайдёт в Figma…»), и снять с него имя чипом значило бы
    /// оставить на экране обрубок со строчной буквы. Поэтому у решения имя не
    /// отрывается вовсе: строка показывается целиком, как в файле, — «Vlad —
    /// зайдёт в Figma…». Разбор при этом тот же, разная только сборка на экран.
    private var carriesAssignee: Bool { tab.itemsAreCheckable }

    private func row(
        _ item: AppState.AtomItem, of meeting: RecordingEntry, section: String
    ) -> some View {
        let atom = item.atom
        let inlineOwner = atom.assignee.map { "\($0) — " } ?? ""
        return ProjectAtomRow(
            checkbox: tab.itemsAreCheckable,
            done: atom.isDone,
            text: carriesAssignee ? atom.body : inlineOwner + atom.body,
            assignee: carriesAssignee ? atom.assignee : nil,
            // Предлагаются те, кого проект знает по своим встречам, а не по этой
            // одной: задачу дают и тому, кого сегодня не было.
            people: carriesAssignee ? state.roster(of: project.id).map(\.name) : [],
            toggle: tab.itemsAreCheckable ? {
                write(item, of: meeting, section: section, to: atom.toggled().item)
            } : nil,
            dropAssignee: carriesAssignee && atom.assignee != nil ? {
                write(item, of: meeting, section: section, to: atom.withoutAssignee().item)
            } : nil,
            setAssignee: carriesAssignee ? { name in
                write(item, of: meeting, section: section, to: atom.with(assignee: name).item)
            } : nil,
            // Правка решения возвращает жирное имя в файл, **если человек его
            // не тронул**: строку он видел слитой, и совпадение начала — не
            // догадка, а факт. Тронул — значит имя теперь часть текста, и
            // жирного в файле не остаётся: разрывать правленную строку обратно
            // на «**имя** — тело» было бы уже догадкой.
            edit: { body in
                let line: String
                if carriesAssignee {
                    line = atom.with(body: body).item
                } else if !inlineOwner.isEmpty, body.hasPrefix(inlineOwner) {
                    line = atom.with(body: String(body.dropFirst(inlineOwner.count))).item
                } else {
                    line = atom.withoutAssignee().with(body: body).item
                }
                write(item, of: meeting, section: section, to: line)
            },
            remove: { write(item, of: meeting, section: section, to: nil) }
        )
    }

    private func write(
        _ item: AppState.AtomItem, of meeting: RecordingEntry, section: String, to line: String?
    ) {
        state.editAtom(
            in: meeting, section: section, index: item.index, expecting: item.raw, to: line
        )
    }

    // MARK: - Встречи

    @ViewBuilder
    private var meetingList: some View {
        if meetings.isEmpty {
            emptyTab("Пока ни одной встречи",
                     "Поставьте проекту метку на встрече — и она появится здесь.")
        } else {
            VStack(alignment: .leading, spacing: Tokens.Projects.Screen.groupGap) {
                ForEach(
                    ProjectMeetingGrouping.grouped(meetings, date: \.date), id: \.group.key
                ) { group in
                    VStack(alignment: .leading, spacing: Tokens.Projects.Screen.groupHeaderGap) {
                        if let header = group.group.header {
                            Text(header)
                                .typo(Tokens.Projects.Typo.groupHeader)
                                .foregroundStyle(Tokens.Settings.header)
                                .padding(.horizontal, Tokens.Projects.Screen.groupHeaderInset)
                        }
                        SettingsCard(
                            hPadding: Tokens.Projects.Screen.meetingCardHPadding,
                            rows: group.items.map { entry in
                                AnyView(ProjectMeetingRow(
                                    title: entry.title,
                                    when: SidebarDayGrouping.day(for: entry.date).header
                                        ?? ProjectCardText.recency(of: entry.date),
                                    duration: entry.duration > 0
                                        ? SidebarMeta.durationText(entry.duration) : "",
                                    subject: entry.subtitleText,
                                    open: { state.selectRecording(entry) }
                                ))
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Участники

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
            SettingsCard(
                hPadding: Tokens.Projects.Screen.personCardHPadding,
                rows: people.map { person in
                    AnyView(ProjectPersonRow(
                        name: person.name, subtitle: ProjectRoster.subtitle(for: person)
                    ))
                }
            )
        }
    }

    private func emptyTab(_ title: String, _ explanation: String) -> some View {
        SettingsCard(
            hPadding: Tokens.Projects.Screen.meetingCardHPadding,
            rows: [AnyView(
                VStack(alignment: .leading, spacing: Tokens.Projects.Screen.rowLineGap) {
                    Text(title)
                        .typo(Tokens.Projects.Typo.title)
                        .foregroundStyle(Tokens.Settings.title)
                    Text(explanation)
                        .typo(Tokens.Projects.Typo.body)
                        .foregroundStyle(Tokens.Projects.quiet)
                }
                .padding(.vertical, Tokens.Projects.Screen.rowVPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            )]
        )
    }
}
