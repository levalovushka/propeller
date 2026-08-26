import SwiftUI
import PropellerUI
import PropellerPure
import ServiceManagement

/// Настройки, как их видит человек, — состояние правой панели.
///
/// # Разделы вернулись
///
/// До 2026-08-26 всё жило одним столбцом групп: вкладки убрали 2026-08-07 по
/// правилу «всё помещается в один столбец» (`design/settings.md` §3.6). Правило
/// было верным для пятнадцати строк и перестало быть верным для двадцати одной
/// — столбец стал длиннее экрана, а находимость в нём держалась на порядке
/// групп, который человек целиком не видит. Решение владельца: разделы, канон
/// переписан под них.
///
/// Разделы **не вкладки**: они стоят в рельсе, на месте списка встреч, и
/// открытый раздел — часть маршрута (`AppState.PaneRoute`). Поэтому «настройки
/// открыты, но раздела нет» невыразимо, а ⌘, всегда ведёт в первый.
///
/// # Что не изменилось
///
/// Каждая строка по-прежнему применяется сразу, ни «Сохранить», ни «Применить».
/// Модалка ровно одна и ровно там, где `design/notifications.md` §5 её
/// разрешает: необратимое действие по клику человека («Удалить аудио встреч?»).
/// Настройки того, что не выбрано, не показываются (§5.4).
///
/// Вёрстка — `PropellerUI/SettingsKit.swift` и `SettingsControls.swift`. Здесь
/// только то, что читает и пишет `Preferences`, `AppState` и Keychain.
struct SettingsPane: View {
    @ObservedObject var state: AppState
    let section: SettingsSection

    var body: some View {
        switch section {
        case .general:       GeneralSettingsPage(state: state)
        case .notifications: NotificationsSettingsPage()
        case .storage:       StorageSettingsPage(state: state)
        case .transcript:    TranscriptSettingsPage(state: state)
        case .models:        ModelsSettingsPage(state: state)
        case .mcp:           MCPSettingsPage(state: state)
        }
    }
}

