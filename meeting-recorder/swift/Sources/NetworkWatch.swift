import Foundation
import Network
import PropellerPure

/// Есть ли сеть прямо сейчас — для тех мест, где ответ нужен **до** нажатия.
///
/// Правило чистое и замеренное (`NetworkPresence`), здесь только привод.
/// Монитор один на приложение: `NWPathMonitor` держит поток, и заводить его
/// на каждую открытую модалку значило бы платить за ответ, который один на всех.
///
/// Стартует лениво — с первого читателя. Приложение, которое ни разу не
/// собиралось ничего публиковать, за сеть не платит.
@MainActor
final class NetworkWatch: ObservableObject {

    static let shared = NetworkWatch()

    /// `true` до первого ответа монитора: до него мы не знаем, что сети нет, а
    /// гасить кнопку «на всякий случай» — врать в самом частом случае.
    @Published private(set) var isOnline = true

    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = NetworkPresence.isOnline(
                satisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map(\.name)
            )
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "propeller.network-watch"))
    }
}
