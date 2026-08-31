import Foundation
import PropellerPure
import Security

enum KeychainHelper {
    private static let service = "com.simplyai.meeting-recorder"

    /// Записать значение. `false` — Keychain отказал, и прежнее значение при
    /// этом **осталось на месте**.
    ///
    /// Раньше здесь стояло «удалить, потом добавить», и результата не спрашивали
    /// ни у того, ни у другого. Две беды сразу: отказ добавления оставлял
    /// человека без ключа, который у него уже работал (поле в настройках при
    /// этом продолжало показывать набранное — оно живёт в `@State`, а не в
    /// Keychain), и о самом отказе никто не узнавал. Ключ пишется на каждое
    /// нажатие клавиши, так что окно между удалением и добавлением открывалось
    /// десятки раз за один ввод.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let step = KeychainOutcome.afterUpdate(
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        )
        switch step {
        case .done:
            return true
        case .refused(let status):
            complain("запись", account: account, status: status)
            return false
        case .add:
            var add = query
            add[kSecValueData as String] = data
            guard case .refused(let status) =
                KeychainOutcome.afterAdd(SecItemAdd(add as CFDictionary, nil))
            else { return true }
            complain("добавление", account: account, status: status)
            return false
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let data = item as? Data
        switch KeychainOutcome.afterRead(status, gotData: data != nil) {
        case .found:
            return data.flatMap { String(data: $0, encoding: .utf8) }
        case .absent:
            return nil
        case .refused(let status):
            complain("чтение", account: account, status: status)
            return nil
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// В лог — имя ящика и код, никогда значение: в этих ящиках лежат ключи от
    /// платных API.
    private static func complain(_ what: String, account: String, status: Int32) {
        NSLog("[Keychain] \(what) «\(account)» отклонено: OSStatus \(status)")
    }
}
