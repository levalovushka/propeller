import XCTest
@testable import PropellerPure

/// Правила шумности телеметрии. Куплены разбором 2026-08-21, где два «пожара»
/// оказались лестницами ретраев: 37 отказов расшифровки у двух человек — и все
/// пятеро дошли до саммари; 28 отказов установки движка у двенадцати — и
/// одиннадцать из четырнадцати саммари получили.
final class TelemetryNoiseTests: XCTestCase {

    func testOnlyTheFirstFailureOfASeriesIsReported() {
        XCTAssertTrue(TelemetryNoise.reportsFailure(attempt: 1))
        for attempt in 2...10 {
            XCTAssertFalse(
                TelemetryNoise.reportsFailure(attempt: attempt),
                "ступень \(attempt) — та же беда, а не новая"
            )
        }
    }

    /// Счётчик приходит с диска и в старых записях мог быть нулём или мусором.
    /// Ошибаться безопасно в сторону «сообщить»: пропущенный инцидент невидим,
    /// лишний виден и стоит одного сигнала.
    func testAnUnknownAttemptCountIsStillReported() {
        XCTAssertTrue(TelemetryNoise.reportsFailure(attempt: 0))
        XCTAssertTrue(TelemetryNoise.reportsFailure(attempt: -3))
    }

    func testASetupFailureIsReportedOnceButANewCauseIsHeard() {
        XCTAssertTrue(TelemetryNoise.reportsSetupFailure(reason: "pull", lastReported: nil))
        XCTAssertFalse(
            TelemetryNoise.reportsSetupFailure(reason: "pull", lastReported: "pull"),
            "тот же отказ на следующем заходе — то же событие"
        )
        XCTAssertTrue(
            TelemetryNoise.reportsSetupFailure(reason: "disk", lastReported: "pull"),
            "кончилось место — другая поломка, и единственный сигнал о ней"
        )
    }

    /// Успех снимает отметку у вызывающего, поэтому отказ после успеха обязан
    /// прозвучать снова: это новый инцидент, а не эхо прежнего.
    func testAFailureAfterASuccessIsANewIncident() {
        XCTAssertTrue(TelemetryNoise.reportsSetupFailure(reason: "pull", lastReported: nil))
    }
}
