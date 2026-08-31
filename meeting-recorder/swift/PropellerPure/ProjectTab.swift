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

    /// Отрывается ли от строки ответственный — чипом, отдельно от текста.
    ///
    /// У задачи — да, её кому-то поручили. У решения — нет: решение не
    /// поручают, его принимают, и снятое чипом имя оставило бы на экране
    /// обрубок со строчной буквы.
    ///
    /// Галочки здесь больше нет ни у кого, и это не «пока не сделали».
    /// Вкладка «Задачи» с чекбоксами была таск-трекером, которым мы не
    /// работаем (VISION §4, MISSION §6), и стоила она не только экрана: клик
    /// по квадрату дописывал `[x]` в файл встречи — тот самый артефакт,
    /// который владелец снял 2026-08-28 (`4caa734`). Поэтому «нельзя
    /// поставить галочку» здесь не флаг со значением `false`, а отсутствие
    /// самого понятия: спросить не у кого.
    public var itemsCarryAssignee: Bool { self == .tasks }

    public static let entry: ProjectTab = .decisions
}
