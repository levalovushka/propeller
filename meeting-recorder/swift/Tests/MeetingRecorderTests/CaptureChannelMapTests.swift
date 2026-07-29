import XCTest
@testable import PropellerPure

/// Названо по тому, что услышал бы человек, если раскладку каналов угадать:
/// вместо своего голоса — гул дальней стороны, вместо дальней стороны — тишина.
/// Ни одно из этого не видно в интерфейсе, пока запись не сядешь слушать.
final class CaptureChannelMapTests: XCTestCase {

    /// Обычный ноутбук: встроенный микрофон моно, тап стерео, у динамиков
    /// входов нет.
    func testBuiltInMicAndSpeakersLandWhereExpected() throws {
        let map = try CaptureChannelLayout.map(sources: [
            .init(role: .microphone, channelCount: 1),
            .init(role: .system, channelCount: 2),
        ])
        XCTAssertEqual(map.micChannelOffset, 0)
        XCTAssertEqual(map.micChannelCount, 1)
        XCTAssertEqual(map.systemChannelOffset, 1)
        XCTAssertEqual(map.systemChannelCount, 2)
        XCTAssertEqual(map.totalChannels, 3)
        XCTAssertTrue(map.hasSystemAudio)
    }

    /// Внешняя карта на выходе: два её линейных входа стоят **перед**
    /// микрофоном. Наивное «канал 0 — микрофон» записало бы сюда пустой линейный
    /// вход и объявило бы, что микрофон молчит.
    func testAnInterfaceWithItsOwnInputsDoesNotStealTheMicChannel() throws {
        let map = try CaptureChannelLayout.map(sources: [
            .init(role: .bystander, channelCount: 2),
            .init(role: .microphone, channelCount: 1),
            .init(role: .system, channelCount: 2),
        ])
        XCTAssertEqual(map.micChannelOffset, 2)
        XCTAssertEqual(map.systemChannelOffset, 3)
        XCTAssertEqual(map.totalChannels, 5)
    }

    /// Стерео-микрофон (внешняя карта, USB-конденсатор). Системный звук уезжает
    /// на канал 2, и раскладка обязана это знать.
    func testAStereoMicPushesSystemAudioOverByOne() throws {
        let map = try CaptureChannelLayout.map(sources: [
            .init(role: .microphone, channelCount: 2),
            .init(role: .system, channelCount: 2),
        ])
        XCTAssertEqual(map.systemChannelOffset, 2)
        XCTAssertEqual(map.totalChannels, 4)
    }

    /// AirPods: вход и выход — одно устройство. Если оно попало в композицию
    /// дважды, каналы посчитаются вдвое, и вторая половина буфера окажется
    /// мусором. Пусть это будет ошибка сборки композиции, а не тихий шум.
    func testTheSameHeadsetCountedTwiceIsRefused() {
        XCTAssertThrowsError(try CaptureChannelLayout.map(sources: [
            .init(role: .microphone, channelCount: 1),
            .init(role: .microphone, channelCount: 1),
            .init(role: .system, channelCount: 2),
        ])) { error in
            XCTAssertEqual(error as? CaptureChannelLayoutError, .duplicateRole(.microphone))
        }
    }

    /// Тап не поднялся — это mic-only, законное состояние: пишем владельца,
    /// помечаем запись. Не отказ.
    func testAMissingTapLeavesAUsableMicOnlyLayout() throws {
        let map = try CaptureChannelLayout.map(sources: [
            .init(role: .microphone, channelCount: 1),
        ])
        XCTAssertFalse(map.hasSystemAudio)
        XCTAssertEqual(map.micChannelCount, 1)
        XCTAssertEqual(map.totalChannels, 1)
    }

    /// А вот микрофона без микрофона не бывает: записывать нечего.
    func testALayoutWithoutAMicrophoneIsAFailure() {
        XCTAssertThrowsError(try CaptureChannelLayout.map(sources: [
            .init(role: .system, channelCount: 2),
        ])) { error in
            XCTAssertEqual(error as? CaptureChannelLayoutError, .noMicrophoneChannels)
        }
    }

    /// Источник с нулём каналов означает, что композиция собралась не так, как
    /// мы её объявили. Считать по ней смещения — значит промахнуться на всё
    /// последующее.
    func testASourceWithNoChannelsIsRefusedRatherThanSkipped() {
        XCTAssertThrowsError(try CaptureChannelLayout.map(sources: [
            .init(role: .microphone, channelCount: 1),
            .init(role: .system, channelCount: 0),
        ])) { error in
            XCTAssertEqual(error as? CaptureChannelLayoutError, .emptySource(.system))
        }
    }
}
