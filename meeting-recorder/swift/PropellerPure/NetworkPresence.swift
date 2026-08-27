import Foundation

/// # Есть ли сейчас сеть
///
/// `NWPath.status == .satisfied` на этот вопрос не отвечает: включённый VPN
/// держит `satisfied` через выключенный Wi-Fi — замерено 2026-08-22, тем же
/// замером живёт `NetworkRestoreEdge` (`ProvisioningRetry.swift`), который
/// поэтому смотрит на состав интерфейсов, а не только на статус.
///
/// Здесь тот же замер, но другой вопрос: не «сеть переменилась», а «сеть есть
/// прямо сейчас». Правило: путь удовлетворён **и** среди интерфейсов есть хоть
/// один не-туннель. Туннель без несущего линка — это ровно та картинка, в
/// которой `satisfied` врёт.
public enum NetworkPresence {

    /// Префиксы имён интерфейсов, которые сами по себе сетью не являются.
    ///
    /// `utun` — VPN и Personal Hotspot от iCloud, `ipsec`/`ppp` — старые
    /// туннели. Список короткий намеренно: длинный означал бы, что мы решаем
    /// за систему, а не читаем её.
    static let tunnelPrefixes = ["utun", "ipsec", "ppp"]

    /// `interfaces` — имена интерфейсов пути, в любом порядке.
    public static func isOnline(satisfied: Bool, interfaces: [String]) -> Bool {
        guard satisfied else { return false }
        return interfaces.contains { name in
            !tunnelPrefixes.contains { name.hasPrefix($0) }
        }
    }
}
