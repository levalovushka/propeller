import Foundation

/// Что рельс ещё должен спросить, когда экран настройки уже позади.
///
/// Онбординг был шестью плашками. Два его вопроса — календарь и имя — не
/// разрешения и ничего не держат: приложение пишет, расшифровывает и делает
/// саммари без обоих. Спрашивать их лучше изнутри приложения, где видно, ради
/// чего ответ, — поэтому они переехали в рельс одним блоком у его подошвы.
/// На отдельном экране осталось то, что нужно спросить у самой macOS.
///
/// Здесь и решение, какой вопрос сейчас на виду, и его слова: тест может
/// поставить «календарь уже выдан, имени нет», не поднимая EventKit, и увидеть
/// ровно то, что увидит человек.
public enum SetupPrompt: String, Equatable, Sendable, CaseIterable {
    case calendar
    case name

    /// Место в счётчике «1/2».
    ///
    /// Закреплено, а не выведено из того, что осталось спросить: счётчик говорит,
    /// сколько пути пройдено, и шаг имени, назвавший себя «1/1» из-за уже
    /// подключённого календаря, соврал бы про длину блока ровно тогда, когда она
    /// другая.
    public var index: Int {
        switch self {
        case .calendar: return 1
        case .name:     return 2
        }
    }

    public static var total: Int { allCases.count }

    public var counter: String { "\(index)/\(Self.total)" }

    public var title: String {
        switch self {
        case .calendar: return "Подключите календарь"
        case .name:     return "Как вас зовут?"
        }
    }

    /// Вторая строка — всегда про то, что приложение с ответом сделает. Вопрос,
    /// который не говорит, зачем он, — это форма.
    public var subtitle: String {
        switch self {
        case .calendar: return "Возьмём там встречи и имена"
        case .name:     return "Учтём в расшифровках"
        }
    }

    /// Подпись на кнопке — или nil у шага, который отвечают полем.
    public var actionTitle: String? {
        switch self {
        case .calendar: return "Подключить"
        case .name:     return nil
        }
    }

    /// Подсказка в поле — или nil у шага, который отвечают кнопкой.
    public var fieldPlaceholder: String? {
        switch self {
        case .calendar: return nil
        case .name:     return "Ваше имя"
        }
    }
}

public enum SetupPromptMachine {

    /// Шаг, который показывает рельс, или nil — блоку больше нечего спрашивать.
    ///
    /// Вопрос считается закрытым не только ответом на него. Календарь закрыт,
    /// если человек уже нажал «Подключить» — что бы ни ответила система: это
    /// предложение, а не ворота, и второй раз спрашивать его не за что. Имя
    /// закрыто, если оно уже известно, и это единственное, что отличает
    /// установку с нуля от обновления с 1.14, где имя спрашивали на своём экране.
    /// Спросить его снова было бы не мягким предложением, а приложением, которое
    /// не помнит разговора.
    ///
    /// Пропустить блок нельзя, и это осознанно: он ничего не держит — записи,
    /// расшифровки и саммари идут поверх него, — поэтому «пропустить» было бы
    /// кнопкой, отменяющей то, что и так ничего не стоит. Он занимает подошву
    /// рельса, пока на него не ответят.
    public static func step(
        setupCompleted: Bool,
        calendarGranted: Bool,
        calendarAsked: Bool,
        knownName: String
    ) -> SetupPrompt? {
        guard setupCompleted else { return nil }
        if !calendarGranted, !calendarAsked { return .calendar }
        if knownName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .name }
        return nil
    }
}
