import XCTest
@testable import PropellerPure

/// Названо по тому, чем это кончалось для человека: он нажимал «записать», а
/// получал файл, в котором дальней стороны нет, — и узнавал об этом через час,
/// когда садился читать саммари.
final class CapturePathTests: XCTestCase {

    private func caps(system: Bool = true, ready: Bool = true) -> CaptureCapabilities {
        CaptureCapabilities(wantsSystemAudio: system, sharedClockReady: ready)
    }

    /// Обычная машина: общие часы, и микрофон как последняя ступень.
    func testAWorkingMachineRecordsOnTheSharedClock() {
        XCTAssertEqual(CapturePathPolicy.ladder(caps()), [.processTap, .microphoneOnly])
    }

    /// Разрешение на захват звука не выдано (или отозвали) — прогрев это
    /// выяснил. Записывать всё равно надо: человек получит свой голос и
    /// пометку, что дальней стороны нет.
    func testWithoutTheSharedClockWeStillRecordTheOwner() {
        XCTAssertEqual(CapturePathPolicy.ladder(caps(ready: false)), [.microphoneOnly])
    }

    /// Человек выключил системный звук в настройках. Это его решение, и никакая
    /// лестница не имеет права его обойти — даже если путь прекрасно готов.
    func testTurningSystemAudioOffIsObeyedEvenWhenEverythingWorks() {
        XCTAssertEqual(CapturePathPolicy.ladder(caps(system: false)), [.microphoneOnly])
        XCTAssertEqual(CapturePathPolicy.ladder(caps(system: false, ready: false)), [.microphoneOnly])
    }

    /// Лестница никогда не заканчивается ничем: последняя ступень всегда та,
    /// которая не может не подняться.
    func testEveryLadderEndsWithSomethingThatAlwaysWorks() {
        for system in [true, false] {
            for ready in [true, false] {
                let ladder = CapturePathPolicy.ladder(caps(system: system, ready: ready))
                XCTAssertEqual(ladder.last, .microphoneOnly)
                XCTAssertFalse(ladder.isEmpty)
            }
        }
    }

    /// Запись экрана захвату не нужна ни на одном пути. Разрешение в приложении
    /// осталось не для звука, а для детектора встреч, и путать эти два запроса
    /// нельзя — человек, отказавший в экране, теряет автозапуск, а не
    /// собеседников в записи.
    func testNoCapturePathAsksForScreenRecording() {
        for path in CapturePath.allCases {
            XCTAssertFalse(CapturePathPolicy.needsScreenRecording(path))
        }
    }

    /// Путей ровно два. Третий появлялся дважды и оба раза был запасным на
    /// случай, когда основной не работает; на месте страховки теперь честный
    /// mic-only, а не вторая правда про то, как устроены дорожки.
    func testThereAreExactlyTwoPaths() {
        XCTAssertEqual(Set(CapturePath.allCases), [.processTap, .microphoneOnly])
    }
}

/// Названо по тому, что человек делает в середине каждого второго звонка:
/// надевает AirPods. Значения здесь — **подписи состояния устройств** (вход,
/// выход, жив ли тот выход, что лежит в составе), а не идентификатор одного
/// устройства: агрегат держит по UID и то, и другое.
final class DeviceChangeCoalescerTests: XCTestCase {

    /// Одно подключение — несколько уведомлений подряд. Перезапуск должен быть
    /// один, иначе мы нашинкуем полсекунды звука в мелкую тишину.
    func testPuttingOnAirPodsRestartsCaptureExactlyOnce() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "BuiltInMic|ok")
        XCTAssertEqual(coalescer.observe(deviceUID: "AirPods|ok", at: 0), .ignore)
        XCTAssertEqual(coalescer.observe(deviceUID: "AirPods|ok", at: 0.1), .ignore)
        XCTAssertEqual(coalescer.observe(deviceUID: "AirPods|ok", at: 0.4), .ignore)
        XCTAssertEqual(coalescer.settle(at: 0.5), .ignore)      // окно ещё идёт
        XCTAssertEqual(coalescer.settle(at: 2.0), .restart)
        XCTAssertEqual(coalescer.settle(at: 3.0), .ignore)      // серия закрыта
        XCTAssertEqual(coalescer.restartCount, 1)
        XCTAssertEqual(coalescer.currentDeviceUID, "AirPods|ok")
    }

    /// После пересборки мы сидим на новом составе, но счётчик перезапусков —
    /// это счётчик того, сколько раз запись уже платила, и обнулять его нельзя:
    /// иначе дёргающееся устройство никогда не упрётся в потолок.
    func testRebindingAfterARestartKeepsTheTally() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "A|ok")
        _ = coalescer.observe(deviceUID: "B|ok", at: 0)
        XCTAssertEqual(coalescer.settle(at: 2), .restart)
        coalescer.rebind(to: "B|ok")
        XCTAssertEqual(coalescer.restartCount, 1)
        XCTAssertEqual(coalescer.currentDeviceUID, "B|ok")
        // И «изменение» обратно на то же самое ничего не стоит.
        XCTAssertEqual(coalescer.observe(deviceUID: "B|ok", at: 3), .ignore)
        XCTAssertEqual(coalescer.settle(at: 6), .ignore)
        XCTAssertEqual(coalescer.restartCount, 1)
    }

    /// Bluetooth-профиль дёрнулся и вернулся на то же устройство. Перезапускать
    /// нечего: мы уже сидим ровно на нём.
    func testAFlickerThatEndsWhereItStartedDoesNotTouchTheRecording() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "BuiltInMic|ok")
        _ = coalescer.observe(deviceUID: "AirPods|ok", at: 0)
        XCTAssertEqual(coalescer.observe(deviceUID: "BuiltInMic|ok", at: 0.3), .ignore)
        XCTAssertEqual(coalescer.settle(at: 5.0), .ignore)
        XCTAssertEqual(coalescer.restartCount, 0)
    }

    /// Человек переключался: наушники, колонки, снова наушники — всё внутри
    /// окна. Считается последнее, и перезапуск один.
    func testFlippingBetweenDevicesInsideTheWindowCostsOneRestart() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "BuiltInMic|ok")
        _ = coalescer.observe(deviceUID: "AirPods|ok", at: 0)
        _ = coalescer.observe(deviceUID: "Display|ok", at: 0.2)
        _ = coalescer.observe(deviceUID: "AirPods|ok", at: 0.4)
        XCTAssertEqual(coalescer.settle(at: 2.0), .restart)
        XCTAssertEqual(coalescer.currentDeviceUID, "AirPods|ok")
        XCTAssertEqual(coalescer.restartCount, 1)
    }

    /// Два настоящих переключения за встречу — два перезапуска. Дебаунс не
    /// должен склеивать то, что случилось через десять минут.
    func testTwoRealSwitchesDuringAMeetingAreTwoRestarts() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "BuiltInMic|ok")
        _ = coalescer.observe(deviceUID: "AirPods|ok", at: 0)
        XCTAssertEqual(coalescer.settle(at: 2), .restart)
        _ = coalescer.observe(deviceUID: "BuiltInMic|ok", at: 600)
        XCTAssertEqual(coalescer.settle(at: 602), .restart)
        XCTAssertEqual(coalescer.restartCount, 2)
    }

    /// Виртуальная карта в цикле переключений. Двенадцать дыр в записи — уже
    /// плохо; сто — это уже не запись. Останавливаемся, говорим об этом **один
    /// раз** и больше не трогаем запись до конца встречи.
    func testADeviceThatFlapsForeverStopsCostingTheRecording() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "A", debounce: 0.5, maxRestarts: 3)
        var now: TimeInterval = 0
        var decisions: [DeviceChangeCoalescer.Decision] = []
        for i in 0..<6 {
            _ = coalescer.observe(deviceUID: i.isMultiple(of: 2) ? "B" : "A", at: now)
            now += 1
            decisions.append(coalescer.settle(at: now))
            now += 1
        }
        XCTAssertEqual(decisions, [.restart, .restart, .restart, .giveUp, .ignore, .ignore])
        XCTAssertEqual(coalescer.restartCount, 3)
        XCTAssertTrue(coalescer.hasGivenUp)
    }

    /// Устройство из состава пропало совсем (выключили монитор, выдернули
    /// USB-карту). В подписи это отдельное состояние — и именно оно, а не выбор
    /// другого вывода по умолчанию, стоит пересборки.
    func testTheBoundOutputDisappearingCountsAsAChange() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "BuiltInMic|ok")
        _ = coalescer.observe(deviceUID: "BuiltInMic|исчезло", at: 0)
        XCTAssertEqual(coalescer.settle(at: 2), .restart)
        XCTAssertEqual(coalescer.currentDeviceUID, "BuiltInMic|исчезло")
    }

    /// А вот отсутствие устройства ввода вовсе — тоже состояние, и `nil` в
    /// подписи не должен схлопываться с «ничего не ждём».
    func testAMissingDeviceIsStillAnObservableState() {
        var coalescer = DeviceChangeCoalescer(boundDeviceUID: "BuiltInMic|ok")
        _ = coalescer.observe(deviceUID: nil, at: 0)
        XCTAssertEqual(coalescer.settle(at: 2), .restart)
        XCTAssertNil(coalescer.currentDeviceUID)
    }
}
