import Foundation
import Sparkle

/// Thin shared wrapper around Sparkle's standard updater (plan-v2 5.3 / SHIP-04).
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
