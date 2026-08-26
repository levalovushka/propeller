import Foundation

/// Разделы настроек — Figma `settings` (254:3399), шесть экранов.
///
/// # Почему их снова шесть
///
/// Вкладки из настроек убрали 2026-08-07 по правилу «всё помещается в один
/// столбец групп» (`design/settings.md` §3.6). Правило было верным для
/// пятнадцати строк и перестало быть верным для двадцати одной: столбец стал
/// длиннее экрана, а находимость в нём держалась на порядке групп, который
/// человек не видит целиком. Решение владельца 2026-08-26 — разделы, и канон
/// переписан под них.
///
/// Разделы **не вкладки**: они живут в рельсе, на месте списка встреч, и
/// открытый раздел — часть маршрута (`AppState.PaneRoute`), а не состояние
/// внутри экрана. Поэтому «настройки открыты, но раздела нет» невыразимо.
///
/// Порядок — по моменту жизни продукта, тот же довод, что и у порядка групп
/// (§5.7): что решает система → о чём она сообщает → где лежат файлы → во что
/// превращается звук → кто пишет саммари → кто ещё читает архив.
public enum SettingsSection: String, CaseIterable, Equatable, Sendable {
    case general
    case notifications
    case storage
    case transcript
    case models
    case mcp

    /// Заголовок раздела. Один и тот же в рельсе и над содержимым: строка
    /// рельса и шапка страницы — одно и то же место, названное дважды.
    public var title: String {
        switch self {
        case .general:       return "Основные"
        case .notifications: return "Уведомления"
        case .storage:       return "Хранилище"
        case .transcript:    return "Расшифровка"
        case .models:        return "Модели"
        case .mcp:           return "MCP"
        }
    }

    /// SF Symbol строки рельса.
    public var symbol: String {
        switch self {
        case .general:       return "gearshape.fill"
        case .notifications: return "bell.fill"
        case .storage:       return "archivebox.fill"
        case .transcript:    return "text.bubble.fill"
        case .models:        return "sparkle"
        case .mcp:           return "point.3.connected.trianglepath.dotted"
        }
    }

    /// Куда ведёт ⌘, и строка рельса: первый раздел, а не последний открытый.
    /// Запомненный раздел — состояние, которое переживает перезапуск и ничего
    /// им не отвечает: человек, открывший настройки через месяц, попадает туда,
    /// где был в прошлый раз, и не знает почему.
    public static let entry: SettingsSection = .general
}
