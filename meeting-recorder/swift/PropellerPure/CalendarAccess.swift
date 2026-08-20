import Foundation

/// Что система на самом деле ответила про календарь.
///
/// Три состояния, а не «дали / не дали»: разница между «ещё не спрашивали» и
/// «отказали» — это разница между «спросить» и «увести в системные настройки».
/// Повторный запрос после отказа окна не показывает: tccd отвечает молча, и
/// кнопка «Попробовать снова» выглядела бы сломанным приложением.
///
/// `writeOnly` живёт здесь как `denied`: право дописывать события ничего не
/// говорит о праве их читать, а читаем мы.
public enum CalendarAccess: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// Строка календаря в настройках: что она говорит и что предлагает нажать.
///
/// Почему строка вообще есть. Календарь **называет** записи
/// (`CalendarService.suggestedRecordingTitle`), и когда доступа нет, названия
/// начинает придумывать модель — молча. Так и случилось 2026-08-15: сборку
/// стали подписывать с hardened runtime ради нотаризации, а календарного
/// entitlement в подписи не было, и tccd с тех пор отказывал **не показывая
/// окна** — «requires entitlement com.apple.security.personal-information.
/// calendars but it is missing». Пять дней встречи назывались «Запись
/// 18.08.2026, 14:04», и ни приложение, ни System Settings об этом не говорили
/// ни слова. Строка и есть тот свидетель, которого не хватало.
///
/// Это не настройка, а ответ системы — тот же жанр, что отказ автозапуска в
/// соседней ячейке: показываем ровно тогда, когда есть что сказать, и говорим
/// то, что человек может сделать.
public enum CalendarSettingsRow: Equatable, Sendable {
    /// Календарём не пользуемся. Одно нажатие — и пользуемся.
    case offer
    /// Всё на месте: события читаются, названия приезжают оттуда.
    case granted
    /// Приложение календарь ждёт, а система ещё не спрошена. Окно покажется,
    /// поэтому спрашиваем сами, а не отправляем человека в System Settings.
    case ask
    /// Система отказала. Просить снова бессмысленно — только руками.
    case blocked

    public static func state(enabled: Bool, access: CalendarAccess) -> CalendarSettingsRow {
        // Выключен в приложении — предложение, каким бы ни был ответ системы:
        // выданное однажды разрешение не значит, что календарём пользуются.
        guard enabled else { return .offer }
        switch access {
        case .granted:       return .granted
        case .notDetermined: return .ask
        case .denied:        return .blocked
        }
    }

    /// Вторая строка ячейки — или nil, когда сказать нечего.
    ///
    /// У выданного доступа подписи нет: справа галочка, и абзац под ней
    /// объяснял бы работающее. У предложения подпись говорит, что приложение
    /// с ответом сделает, — вопрос без «зачем» это форма.
    public var subtitle: String? {
        switch self {
        case .offer:   return "Возьмём оттуда названия встреч и участников"
        case .granted: return nil
        case .ask:     return "Доступ не выдан — названия придумывает модель"
        case .blocked: return "macOS не даёт доступ — названия придумывает модель"
        }
    }

    /// Подпись на кнопке — или nil там, где нажимать нечего.
    public var actionTitle: String? {
        switch self {
        case .offer:   return "Подключить"
        case .granted: return nil
        case .ask:     return "Разрешить"
        case .blocked: return "Открыть доступ"
        }
    }

    /// Нажатие спрашивает саму систему (`.offer`, `.ask`) или ведёт в System
    /// Settings (`.blocked`).
    public var opensSystemSettings: Bool { self == .blocked }

    public var showsCheckmark: Bool { self == .granted }
}
