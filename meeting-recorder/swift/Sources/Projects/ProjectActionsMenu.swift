import SwiftUI
import PropellerUI
import PropellerPure

/// Что можно сделать с проектом — Figma 268:12170.
///
/// Один компонент на два места: карточка в сетке и шапка экрана проекта. То,
/// что делают с проектом, не должно зависеть от того, смотрят на него снаружи
/// или изнутри, — а два списка пунктов разъезжаются на первом же добавленном.
///
/// Меню системное, а не нарисованная плита в 220 pt: нарисованное теряет
/// клавиатуру и доступность, и видно у него ровно триггер. То же решение уже
/// записано у `SettingsMenu`.
///
/// Чего в нём нет из макета: **«Закрепить»** — закрепления в спеке проектов
/// не существует, порядок задаёт сортировка; **«Добавить записи»** — привязка
/// встреч уедет на вкладку «Встречи», где список и живёт.
struct ProjectActionsMenu: View {
    @ObservedObject var state: AppState
    let project: Project

    @State private var confirmingDelete = false

    var body: some View {
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
            Button("Удалить проект", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog(
            "Удалить проект «\(project.name)»?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить проект", role: .destructive) { state.deleteProject(project.id) }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Встречи останутся на месте — с них снимется метка.")
        }
    }
}
