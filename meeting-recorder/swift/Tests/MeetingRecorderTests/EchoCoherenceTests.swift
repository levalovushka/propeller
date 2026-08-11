import XCTest
@testable import PropellerPure

/// Сигнал, по которому гейт отличает эхо из колонки от речи владельца.
///
/// Здесь проверяется именно то свойство, из-за которого прежнее правило
/// провалилось: ответ не должен зависеть от **громкости**. Поэтому почти каждый
/// тест прогоняется дважды — с эхом тише референса и с эхом громче него.
final class EchoCoherenceTests: XCTestCase {

    private let sampleRate: Float = 16_000
    private let frames = 16_000   // секунда: хватает на 28 кадров оценщика

    // MARK: - Материал

    /// Речеподобный сигнал: несколько формант в речевой полосе с дрожащей
    /// амплитудой. Чистого тона мало — у него одна ячейка, и медиана кадра
    /// перестаёт что-либо значить.
    private func voice(seed: UInt64, count: Int, gain: Float = 1) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        _ = rng
        var state = seed | 1
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
        let tones: [Float] = [310, 620, 1450, 2380]
        var out = [Float](repeating: 0, count: count)
        var envelope: Float = 0
        for i in 0..<count {
            let t = Float(i) / sampleRate
            // Огибающая слогов — 6 Гц, плюс шум, чтобы спектр не был линейчатым.
            envelope = 0.9 * envelope + 0.1 * abs(sin(2 * .pi * 6 * t))
            var sample: Float = 0
            for (index, f) in tones.enumerated() {
                sample += sin(2 * .pi * (f + Float(seed % 40)) * t) / Float(index + 2)
            }
            out[i] = gain * (sample * envelope * 0.25 + noise() * 0.01 * envelope)
        }
        return out
    }

    /// Эхо: та же речь, задержанная на дорогу от колонки до микрофона (30 мс —
    /// замер STATE.md M6) и приглушённая комнатой.
    private func echo(of source: [Float], gain: Float) -> [Float] {
        let delay = Int(0.030 * sampleRate)
        var out = [Float](repeating: 0, count: source.count)
        for i in delay..<source.count {
            // Простая комната: прямой звук плюс одно отражение.
            out[i] = gain * (source[i - delay] + 0.4 * source[i - delay / 2])
        }
        return out
    }

    private func share(mic: [Float], system: [Float], chunk: Int = 800) -> Double {
        var estimator = EchoCoherence(sampleRate: sampleRate)
        var loud = 0
        var unexplained = 0
        var offset = 0
        while offset < mic.count {
            let end = min(offset + chunk, mic.count)
            let cells = estimator.note(
                mic: Array(mic[offset..<end]), system: Array(system[offset..<end])
            )
            loud += cells.loud
            unexplained += cells.unexplained
            offset = end
        }
        XCTAssertGreaterThan(loud, 0, "оценщик не проголосовал ни одной ячейкой")
        return Double(unexplained) / Double(loud)
    }

    // MARK: - Что сигнал обязан различать

    func testЭхоИзКолонкиОбъясняетсяДальнейСтороной() {
        let far = voice(seed: 7, count: frames)
        for gain: Float in [0.3, 1.0, 3.0] {
            let observed = share(mic: echo(of: far, gain: gain), system: far)
            XCTAssertLessThan(
                observed, FeedGate.ownerShare,
                "эхо с усилением \(gain) прочитано как речь владельца — правило снова зависит от громкости"
            )
        }
    }

    func testРечьВладельцаНеОбъясняетсяНичем() {
        let far = voice(seed: 7, count: frames)
        let owner = voice(seed: 91, count: frames)
        // Микрофон слышит только владельца, референс живёт своей жизнью.
        let observed = share(mic: owner, system: far)
        XCTAssertGreaterThan(observed, 0.5)
    }

    func testВладелецПоверхЭхаВидендажеБудучиТишеЕго() {
        // Рабочий случай Левона: своя речь на 5 dB **тише** эха дальней стороны.
        let far = voice(seed: 7, count: frames)
        let heard = echo(of: far, gain: 1.0)
        let owner = voice(seed: 91, count: frames, gain: 0.56)
        let mixed = zip(heard, owner).map(+)
        XCTAssertGreaterThan(
            share(mic: mixed, system: far), FeedGate.ownerShare,
            "порция с речью владельца не уйдёт движку — экономия украла слово"
        )
    }

    // MARK: - Когда замера нет

    func testБезСистемнойДорожкиЗамераНет() {
        var estimator = EchoCoherence(sampleRate: sampleRate)
        let owner = voice(seed: 91, count: frames)
        XCTAssertEqual(estimator.note(mic: owner, system: []), .none)
    }

    func testДоПервогоПолногоКадраЗамераНет() {
        var estimator = EchoCoherence(sampleRate: sampleRate)
        let far = voice(seed: 7, count: 800)
        XCTAssertEqual(estimator.note(mic: echo(of: far, gain: 1), system: far), .none)
    }

    func testНоваяВстречаНачинаетСЧистойПамяти() {
        var estimator = EchoCoherence(sampleRate: sampleRate)
        let far = voice(seed: 7, count: frames)
        _ = estimator.note(mic: echo(of: far, gain: 1), system: far)
        estimator.reset()
        XCTAssertEqual(estimator.note(mic: Array(far[0..<800]), system: Array(far[0..<800])), .none)
    }

    // MARK: - Преобразование

    func testСпектрНаходитТонТамГдеОнЕсть() {
        let fft = RealFFT(count: 2048)
        let bin = 100
        let tone = (0..<2048).map { sin(2 * Float.pi * Float(bin) * Float($0) / 2048) }
        let spectrum = fft.spectrum(of: tone)
        let power = (0..<spectrum.re.count).map {
            spectrum.re[$0] * spectrum.re[$0] + spectrum.im[$0] * spectrum.im[$0]
        }
        XCTAssertEqual(power.firstIndex(of: power.max()!), bin)
    }

    func testСпектрТишиныПуст() {
        let fft = RealFFT(count: 2048)
        let spectrum = fft.spectrum(of: [Float](repeating: 0, count: 2048))
        XCTAssertEqual(spectrum.re.allSatisfy { $0 == 0 }, true)
        XCTAssertEqual(spectrum.im.allSatisfy { $0 == 0 }, true)
    }
}
