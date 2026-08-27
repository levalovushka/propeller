import Foundation

/// Вкладки экрана проекта — Figma `project/*-tab` (254:3400).
///
/// Тип, а не список строк в виде, по той же причине, что у `SettingsSection`:
/// от него зависят и полоса вкладок, и кадры галереи
/// (`UIStateCatalog.projectTabs`), и «вкладка открыта, но какая — неизвестно»
/// становится невыразимым.
///
/// Порядок — макетный: сначала то, ради чего в проект заходят, потом то, из
/// чего он состоит.
public enum ProjectTab: String, CaseIterable, Equatable, Sendable {
    case decisions
    case tasks
    case meetings
    case participants

    public var title: String {
        switch self {
        case .decisions:    return "Решения"
        case .tasks:        return "Задачи"
        case .meetings:     return "Встречи"
        case .participants: return "Участники"
        }
    }

    /// Раздел конспекта, из которого вкладка берёт пункты. Nil — вкладка не про
    /// атомы вовсе.
    public var recapSection: String? {
        switch self {
        case .decisions: return RecapDigest.decisionsTitle
        case .tasks:     return RecapDigest.tasksTitle
        case .meetings, .participants: return nil
        }
    }

    /// Есть ли у пункта настоящий чекбокс.
    ///
    /// У задачи — да. У решения — нет: кружок в макете это **маркер списка, а не
    /// состояние** (решение владельца 2026-08-27), и чекбокса у решения в
    /// markdown не заводится.
    public var itemsAreCheckable: Bool { self == .tasks }

    public static let entry: ProjectTab = .decisions
}
