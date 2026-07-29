import AudioToolbox
import XCTest
@testable import PropellerPure

/// Названо по тому, что человек услышит, если разобрать буфер не так: в своей
/// дорожке — голос собеседника, в дорожке собеседника — тишина. Ни то, ни
/// другое не видно ни в интерфейсе, ни в размере файла.
final class CaptureBuffersTests: XCTestCase {

    /// Собирает список буферов из «каналов по буферам»: каждый элемент —
    /// один `AudioBuffer`, внутри — его каналы, чередующиеся покадрово.
    /// Именно так агрегат и раскладывает свои источники.
    private func makeList(_ buffers: [[[Float]]]) -> (UnsafeMutableAudioBufferListPointer, () -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var allocations: [UnsafeMutableRawPointer] = []
        for (index, channels) in buffers.enumerated() {
            let frames = channels.first?.count ?? 0
            var interleaved = [Float](repeating: 0, count: frames * channels.count)
            for frame in 0..<frames {
                for (channel, samples) in channels.enumerated() {
                    interleaved[frame * channels.count + channel] = samples[frame]
                }
            }
            let bytes = interleaved.count * MemoryLayout<Float>.size
            let raw = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 1), alignment: 16)
            interleaved.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            allocations.append(raw)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels.count),
                mDataByteSize: UInt32(bytes),
                mData: raw
            )
        }
        return (list, {
            allocations.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        })
    }

    /// Обычный случай: микрофон и тап приехали отдельными буферами.
    func testTheMicAndTheTapAreReadFromTheirOwnChannels() {
        let (list, cleanup) = makeList([
            [[1, 2, 3, 4]],       // канал 0 — микрофон
            [[9, 9, 9, 9]],       // канал 1 — тап
        ])
        defer { cleanup() }

        var mic = [Float](repeating: -1, count: 4)
        var system = [Float](repeating: -1, count: 4)
        XCTAssertEqual(
            CaptureBuffers.mixDown(list, from: 0, count: 1, frames: 4, into: &mic), 1
        )
        XCTAssertEqual(
            CaptureBuffers.mixDown(list, from: 1, count: 1, frames: 4, into: &system), 1
        )
        XCTAssertEqual(mic, [1, 2, 3, 4])
        XCTAssertEqual(system, [9, 9, 9, 9])
        XCTAssertEqual(CaptureBuffers.channelCount(of: list), 2)
        XCTAssertEqual(CaptureBuffers.frameCount(of: list), 4)
    }

    /// Тот же агрегат, но всё в одном буфере с чередованием. Разбор обязан
    /// давать тот же ответ — иначе дорожки поменялись бы местами в зависимости
    /// от того, как система решила разложить память.
    func testAnInterleavedBufferGivesTheSameAnswer() {
        let (list, cleanup) = makeList([
            [[1, 2, 3, 4], [9, 9, 9, 9]],
        ])
        defer { cleanup() }

        var mic = [Float](repeating: -1, count: 4)
        var system = [Float](repeating: -1, count: 4)
        CaptureBuffers.mixDown(list, from: 0, count: 1, frames: 4, into: &mic)
        CaptureBuffers.mixDown(list, from: 1, count: 1, frames: 4, into: &system)
        XCTAssertEqual(mic, [1, 2, 3, 4])
        XCTAssertEqual(system, [9, 9, 9, 9])
        XCTAssertEqual(CaptureBuffers.frameCount(of: list), 4)
    }

    /// Внешняя карта отдаёт свои линейные входы первыми. Микрофон стоит за
    /// ними, и наивное «канал 0» записало бы пустой линейный вход.
    func testBystanderInputsBeforeTheMicAreSkipped() {
        let (list, cleanup) = makeList([
            [[0, 0, 0, 0], [0, 0, 0, 0]],   // каналы 0–1: чужие входы
            [[5, 6, 7, 8]],                  // канал 2: микрофон
            [[9, 9, 9, 9]],                  // канал 3: тап
        ])
        defer { cleanup() }

        var mic = [Float](repeating: -1, count: 4)
        CaptureBuffers.mixDown(list, from: 2, count: 1, frames: 4, into: &mic)
        XCTAssertEqual(mic, [5, 6, 7, 8])
    }

    /// Стерео-микрофон сводится в моно **средним**, а не суммой: суммой он был
    /// бы вдвое громче моно, и автогейн в миксе принялся бы это «исправлять».
    func testAStereoMicIsAveragedNotSummed() {
        let (list, cleanup) = makeList([
            [[1, 1, 1, 1], [3, 3, 3, 3]],
        ])
        defer { cleanup() }

        var mic = [Float](repeating: -1, count: 4)
        XCTAssertEqual(
            CaptureBuffers.mixDown(list, from: 0, count: 2, frames: 4, into: &mic), 2
        )
        XCTAssertEqual(mic, [2, 2, 2, 2])
    }

    /// Раскладка не та, какую мы посчитали: каналов меньше, чем мы просим.
    /// Ноль сведённых каналов — это сигнал «состав собрался иначе», и молча
    /// записывать тишину вместо него нельзя.
    func testAskingForAChannelThatIsNotThereReportsZeroRatherThanSilence() {
        let (list, cleanup) = makeList([[[1, 2, 3, 4]]])
        defer { cleanup() }

        var system = [Float](repeating: -1, count: 4)
        XCTAssertEqual(
            CaptureBuffers.mixDown(list, from: 5, count: 1, frames: 4, into: &system), 0
        )
    }

    /// Буфер короче, чем обещали часы: копируем что есть, остальное остаётся
    /// нулями — не читаем за концом.
    func testAShortBufferDoesNotReadPastItsEnd() {
        let (list, cleanup) = makeList([[[1, 2]]])
        defer { cleanup() }

        var mic = [Float](repeating: -1, count: 4)
        CaptureBuffers.mixDown(list, from: 0, count: 1, frames: 4, into: &mic)
        XCTAssertEqual(mic, [1, 2, 0, 0])
    }

    /// Приёмник меньше запрошенного числа кадров — отказываемся, а не пишем за
    /// его границу.
    func testARequestBiggerThanTheDestinationIsRefused() {
        let (list, cleanup) = makeList([[[1, 2, 3, 4]]])
        defer { cleanup() }

        var mic = [Float](repeating: -1, count: 2)
        XCTAssertEqual(
            CaptureBuffers.mixDown(list, from: 0, count: 1, frames: 4, into: &mic), 0
        )
        XCTAssertEqual(mic, [-1, -1])
    }

    func testPeakLooksAtTheRequestedFramesOnly() {
        let samples: [Float] = [0.1, -0.2, 0.9, 0.3]
        XCTAssertEqual(CaptureBuffers.peak(samples), 0.9, accuracy: 0.0001)
        XCTAssertEqual(CaptureBuffers.peak(samples, frames: 2), 0.2, accuracy: 0.0001)
        XCTAssertEqual(CaptureBuffers.peak([], frames: 10), 0)
    }

    /// Клиппинг наружу не выпускаем: индикатор всё равно рисует 0…1.
    func testPeakIsClampedToOne() {
        XCTAssertEqual(CaptureBuffers.peak([2.5, -3.0]), 1)
    }
}
