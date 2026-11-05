import AppKit
import PropellerPure
@testable import PropellerUI
import SwiftUI
import XCTest

/// Сколько процессора стоит движущаяся вейвформа в полосе записи.
///
///     WAVEFORM_CPU=1 swift test --filter WaveformCost
///
/// Две полосы в настоящем окне по десять секунд: с уровнями (полоски движутся,
/// `TimelineView` идёт 10 раз в секунду) и без них (полоски лежат, часов нет).
/// Разница процессорного времени процесса — цена движения. Это верхняя оценка
/// одного вида, а не замер приложения на встрече.
final class WaveformCostTests: XCTestCase {

    @MainActor
    func testMovingBarsCostLittle() throws {
        guard ProcessInfo.processInfo.environment["WAVEFORM_CPU"] != nil else {
            throw XCTSkip("WAVEFORM_CPU не задан")
        }
        let still = try cpuSeconds(moving: false, for: 10)
        let moving = try cpuSeconds(moving: true, for: 10)
        let cores = (moving - still) / 10
        print("WAVEFORM_CPU still=\(still)s moving=\(moving)s extra=\(String(format: "%.4f", cores)) cores")
    }

    @MainActor
    private func cpuSeconds(moving: Bool, for seconds: TimeInterval) throws -> Double {
        var tick = 0
        let levels: RecordingControls.Levels = {
            tick += 1
            let wave = (0..<50).map { Float(0.05 + 0.3 * abs(sin(Double(tick + $0) / 3))) }
            return (wave, wave.reversed())
        }
        let root = RecordingControls(
            elapsed: "12:04", isPaused: false,
            levels: moving ? levels : nil,
            onPause: {}, onStop: {}
        )
        .padding(8)
        .environment(\.colorScheme, .dark)

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 56),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let start = Self.processCPU()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let spent = Self.processCPU() - start
        if moving { XCTAssertGreaterThan(tick, Int(seconds * 5), "часы вейвформы не шли") }
        return spent
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
}
