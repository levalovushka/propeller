import Foundation

/// Вкладки экрана проекта — Figma `project/*-tab` (254:3400).
///
/// Тип, а не список строк в виде, по той же причине, что у `SettingsSection`:
/// от него зависят и полоса вкладок, и кадры галереи
/// (`UIStateCatalog.projectTabs`), и «вкладка открыта, но какая — неизвестно»
/// становится невыразимым.
///
/// **Здесь две из четырёх.** В макете полоса начинается с «Решений» и «Задач»
/// — они приедут вместе с разбором атомов (`plan-projects.md` §12, шаг 4) и
/// встанут перед этими двумя. Заводить их сейчас пустыми значило бы нарисовать
/// вкладку, за которой ничего нет, — ровно то, чем строка «Проекты» в рельсе
/// была месяц.
public enum ProjectTab: String, CaseIterable, Equatable, Sendable {
    case meetings
    case participants

    public var title: String {
        switch self {
        case .meetings:     return "Встречи"
        case .participants: return "Участники"
        }
    }

    public static let entry: ProjectTab = .meetings
}
