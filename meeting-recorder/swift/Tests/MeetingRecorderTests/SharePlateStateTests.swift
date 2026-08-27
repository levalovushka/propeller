import XCTest
@testable import PropellerPure

final class SharePlateStateTests: XCTestCase {

    func testNothingStopsAReadySummaryOnline() {
        XCTAssertNil(SharePlateState.obstacle(hasSummary: true, isOnline: true))
    }

    func testWithoutTheNetworkTheButtonSaysSo() {
        XCTAssertEqual(SharePlateState.obstacle(hasSummary: true, isOnline: false), .offline)
        XCTAssertEqual(
            SharePlateState.Obstacle.offline.reason, "Без интернета не получится"
        )
    }

    /// Сеть появится сама, а пустое саммари от неё не наполнится: сказать про
    /// интернет там, где дело не в нём, — соврать.
    func testAnEmptySummaryIsNamedBeforeTheNetwork() {
        XCTAssertEqual(SharePlateState.obstacle(hasSummary: false, isOnline: false), .nothing)
        XCTAssertEqual(SharePlateState.obstacle(hasSummary: false, isOnline: true), .nothing)
    }
}

final class NetworkPresenceTests: XCTestCase {

    func testWifiIsNetwork() {
        XCTAssertTrue(NetworkPresence.isOnline(satisfied: true, interfaces: ["en0"]))
    }

    /// Тот самый замер 2026-08-22: VPN держит путь удовлетворённым через
    /// выключенный Wi-Fi, и «satisfied» на вопрос «есть ли сеть» не отвечает.
    func testATunnelWithNothingUnderItIsNotNetwork() {
        XCTAssertFalse(NetworkPresence.isOnline(satisfied: true, interfaces: ["utun3"]))
        XCTAssertFalse(
            NetworkPresence.isOnline(satisfied: true, interfaces: ["utun0", "utun3", "ipsec0"])
        )
    }

    /// А VPN поверх живого Wi-Fi — сеть: несущий линк в списке есть.
    func testATunnelOverAliveLinkIsNetwork() {
        XCTAssertTrue(NetworkPresence.isOnline(satisfied: true, interfaces: ["utun3", "en0"]))
    }

    func testAnUnsatisfiedPathIsNeverNetwork() {
        XCTAssertFalse(NetworkPresence.isOnline(satisfied: false, interfaces: ["en0"]))
        XCTAssertFalse(NetworkPresence.isOnline(satisfied: false, interfaces: []))
    }

    func testNoInterfacesAtAllIsNotNetwork() {
        XCTAssertFalse(NetworkPresence.isOnline(satisfied: true, interfaces: []))
    }
}
