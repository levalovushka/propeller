import Foundation

/// Что Keychain ответил и что из этого следует.
///
/// Отдельно от `KeychainHelper`, потому что помощник живёт в executable-таргете
/// и тест до него не дотягивается, а решение здесь ровно одно и оно важное:
/// **«ключа нет» и «мне не дали ключ» — разные ответы**. Помощник их не
/// различал, оба превращались в `nil`, и облачный провайдер молча становился
/// «провайдера нет» (`RecapSkipReason.noProvider`). Отличить «человек не вписал
/// ключ» от «ключ есть, но его не отдали» после этого невозможно — ни в логе,
/// ни в телеметрии, ни глазами.
public enum KeychainRead: Equatable, Sendable {
    /// Элемент есть, данные пришли.
    case found
    /// Элемента нет — законный ответ, а не сбой.
    case absent
    /// Keychain отказал (заперт, ACL не пустил, нет прав). Код — для лога.
    case refused(Int32)
}

/// Что делать дальше после попытки переписать элемент.
public enum KeychainWriteStep: Equatable, Sendable {
    /// Переписан, больше ничего не нужно.
    case done
    /// Элемента ещё не было — добавить.
    case add
    /// Keychain отказал; добавлять нечего и **удалять тем более нечего**.
    case refused(Int32)
}

public enum KeychainOutcome {
    /// `errSecSuccess`. Константами, а не `Security`-именами: PropellerPure не
    /// импортирует фреймворков, а числа эти зафиксированы Apple и не меняются.
    public static let success: Int32 = 0
    /// `errSecItemNotFound`.
    public static let notFound: Int32 = -25300

    /// Ответ `SecItemUpdate`.
    ///
    /// `errSecItemNotFound` здесь — не отказ: элемента просто ещё нет, его
    /// добавляют. Всё остальное — отказ, и он обязан остаться отказом: старая
    /// запись «удалить и добавить заново» на отказе добавления оставляла
    /// человека вообще без ключа, хотя рабочий ключ у него уже был.
    public static func afterUpdate(_ status: Int32) -> KeychainWriteStep {
        switch status {
        case success: return .done
        case notFound: return .add
        default: return .refused(status)
        }
    }

    /// Ответ `SecItemAdd`.
    public static func afterAdd(_ status: Int32) -> KeychainWriteStep {
        status == success ? .done : .refused(status)
    }

    /// Ответ `SecItemCopyMatching`.
    ///
    /// `gotData` — пришли ли байты. Успех без данных считается отказом: это не
    /// «ключа нет», это Keychain сказал «нашёл» и ничего не отдал, и молчать об
    /// этом — ровно та ошибка, из-за которой мы не знаем причину пустого поля.
    public static func afterRead(_ status: Int32, gotData: Bool) -> KeychainRead {
        switch status {
        case success: return gotData ? .found : .refused(status)
        case notFound: return .absent
        default: return .refused(status)
        }
    }
}
