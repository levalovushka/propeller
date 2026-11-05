import XCTest
import PropellerPure

/// Вейвформа рядом с таймером: что человек видит, когда звук есть, когда его
/// нет и когда его микрофон выключен.
final class WaveformBarsTests: XCTestCase {

    func testSilenceLiesFlatButDoesNotDisappear() {
        let silent = Array(repeating: Float(0), count: 50)
        XCTAssertEqual(WaveformBars.heights(mic: silent, system: silent), WaveformBars.flat)
        XCTAssertTrue(WaveformBars.flat.allSatisfy { $0 > 0 })
    }

    /// Пик речи — сотые доли. В линейной шкале голос выглядел бы тишиной.
    func testOrdinarySpeechStandsWellAboveTheFloor() {
        let speech = Array(repeating: Float(0.05), count: 50)
        let quiet = Array(repeating: Float(0), count: 50)
        let bars = WaveformBars.heights(mic: quiet, system: speech)
        XCTAssertTrue(bars.allSatisfy { $0 > 0.4 }, "\(bars)")
    }

    func testTheLouderSideDecidesEachBar() {
        let mic: [Float] = [0, 0, 0, 0, 0.5]
        let system: [Float] = [0.5, 0, 0, 0, 0]
        let bars = WaveformBars.heights(mic: mic, system: system)
        XCTAssertGreaterThan(bars[0], WaveformBars.floor)
        XCTAssertEqual(bars[1], WaveformBars.floor)
        XCTAssertGreaterThan(bars[4], WaveformBars.floor)
    }

    /// Мьют обнуляет микрофон до замера — полоски живут только от собеседников.
    func testAMutedMicLeavesOnlyTheFarSide() {
        let muted = Array(repeating: Float(0), count: 50)
        let far = Array(repeating: Float(0.2), count: 50)
        let bars = WaveformBars.heights(mic: muted, system: far)
        XCTAssertTrue(bars.allSatisfy { $0 > WaveformBars.floor })
    }

    func testTheNewestMomentIsOnTheRight() {
        var system = Array(repeating: Float(0), count: 50)
        system[49] = 1
        let bars = WaveformBars.heights(mic: Array(repeating: 0, count: 50), system: system)
        XCTAssertEqual(bars.last, 1)
        XCTAssertEqual(bars.first, WaveformBars.floor)
    }

    func testAShortHistoryIsPaddedWithSilenceOnTheLeft() {
        let bars = WaveformBars.heights(mic: [1], system: [1])
        XCTAssertEqual(bars.count, WaveformBars.count)
        XCTAssertEqual(bars.last, 1)
        XCTAssertEqual(Array(bars.dropLast()), Array(repeating: WaveformBars.floor, count: 4))
    }

    func testClippingAndGarbageStayInsideTheGlyph() {
        let bars = WaveformBars.heights(mic: [4, .nan, -1, .infinity, 1], system: [0, 0, 0, 0, 0])
        XCTAssertTrue(bars.allSatisfy { (0...1).contains($0) }, "\(bars)")
    }
}
