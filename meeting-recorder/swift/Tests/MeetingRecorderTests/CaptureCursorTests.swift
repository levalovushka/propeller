import XCTest
@testable import PropellerPure

/// Названо по тому, что вышло из дописывания буферов в конец: речь на записи
/// звучит, а эхоподавитель на ней не сходится, потому что дорожки дрожат на
/// единицы миллисекунд. Пользователь этого не слышит — он слышит задвоение,
/// которое из-за этого нечем убрать (M6).
final class CaptureCursorTests: XCTestCase {

    private let rate: Double = 48_000

    func testAnUninterruptedStreamJustAppends() {
        var cursor = CaptureCursor(sampleRate: rate)
        var time: Double = 1_000_000
        for _ in 0..<100 {
            let placement = cursor.place(sampleTime: time, frameCount: 512)
            XCTAssertTrue(placement.isContinuous)
            XCTAssertEqual(placement.writeFrames, 512)
            time += 512
        }
        XCTAssertEqual(cursor.framesWritten, 51_200)
        XCTAssertEqual(cursor.paddedSilenceFrames, 0)
        XCTAssertEqual(cursor.reanchorCount, 0)
    }

    /// Часы записи не начинаются с нуля — важно, что первый буфер задаёт
    /// начало, а не что у него «правильное» значение.
    func testTheFirstBufferDefinesZeroWhateverTheClockSays() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 987_654_321.5, frameCount: 480)
        XCTAssertEqual(cursor.framesWritten, 480)
        XCTAssertEqual(cursor.reanchorCount, 0)
    }

    /// Тот самый дефект: система пропустила буфер. Дописав следующий в конец, мы
    /// сдвинули бы весь остаток записи на 10 мс влево — и так на каждом пропуске.
    func testADroppedBufferBecomesSilence_notAShiftOfEverythingAfterIt() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: 1024, frameCount: 512)   // 512 кадров потеряно
        XCTAssertEqual(placement.silenceFrames, 512)
        XCTAssertEqual(placement.writeFrames, 512)
        XCTAssertFalse(placement.reanchored)
        // Кадр 1536 записи соответствует кадру 1536 часов — сдвига нет.
        XCTAssertEqual(cursor.framesWritten, 1536)
        XCTAssertEqual(cursor.paddedSilenceFrames, 512)
    }

    /// Повтор того же буфера (бывает на переподключении устройства) не должен
    /// удлинять запись: это то же время, а не новое.
    func testARepeatedBufferIsDroppedRatherThanWrittenTwice() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: 0, frameCount: 512)
        XCTAssertEqual(placement.writeFrames, 0)
        XCTAssertEqual(placement.skipFrames, 512)
        XCTAssertTrue(placement.isEmpty)
        XCTAssertEqual(cursor.framesWritten, 512)
        XCTAssertEqual(cursor.droppedOverlapFrames, 512)
    }

    /// Частичное наложение: половина буфера уже записана, половина новая.
    /// Записать целиком — значит вписать 5 мс речи дважды подряд.
    func testAPartiallyOverlappingBufferKeepsOnlyTheNewTail() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: 256, frameCount: 512)
        XCTAssertEqual(placement.skipFrames, 256)
        XCTAssertEqual(placement.writeFrames, 256)
        XCTAssertEqual(cursor.framesWritten, 768)
    }

    /// Дробные `mSampleTime` — норма при компенсации дрейфа между часами
    /// микрофона и вывода. Полкадра туда-сюда это округление, а не пропуск:
    /// иначе мы бы вставляли по кадру тишины несколько раз в секунду.
    func testSubFrameJitterIsRoundingNotAGap() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: 512.4, frameCount: 512)
        XCTAssertTrue(placement.isContinuous)
        XCTAssertEqual(cursor.paddedSilenceFrames, 0)
    }

    /// Человек выдернул наушники, устройство пересоздалось, часы пошли с нуля.
    /// Добить это тишиной по разнице — значит вписать в часовую запись минуты
    /// молчания, которых не было. Честнее привязаться заново.
    func testAClockThatRestartsFromZeroReanchorsInsteadOfInventingSilence() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 500_000_000, frameCount: 512)
        let placement = cursor.place(sampleTime: 0, frameCount: 512)
        XCTAssertTrue(placement.reanchored)
        XCTAssertEqual(placement.writeFrames, 512)
        XCTAssertEqual(placement.silenceFrames, 0)
        XCTAssertEqual(cursor.reanchorCount, 1)
        XCTAssertEqual(cursor.framesWritten, 1024)
    }

    /// Прыжок вперёд на полчаса — тоже не пропуск, а сломанные часы.
    func testAnImplausibleForwardJumpDoesNotPadHalfAnHourOfSilence() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: 1800 * 48_000, frameCount: 512)
        XCTAssertTrue(placement.reanchored)
        XCTAssertEqual(placement.silenceFrames, 0)
        XCTAssertEqual(cursor.paddedSilenceFrames, 0)
    }

    /// Пропуск в пределах разумного — переподключение устройства на пару
    /// секунд — наоборот, обязан стать тишиной: иначе всё, что человек сказал
    /// после, встанет раньше, чем он это сказал.
    func testATwoSecondDropoutIsPaddedHonestly() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: 512 + 2 * 48_000, frameCount: 512)
        XCTAssertEqual(placement.silenceFrames, 96_000)
        XCTAssertFalse(placement.reanchored)
    }

    /// Явный перезапуск захвата (сменилось устройство вывода): дыру мы измеряем
    /// сами по стенным часам и вписываем, а следующий буфер приходит уже с
    /// чужой шкалой — и она не должна ни во что превратиться.
    func testAnExplicitRestartPadsTheOutageAndStartsANewClock() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 48_000)   // секунда записи
        cursor.reanchor()
        let padded = cursor.padGap(seconds: 0.4)
        XCTAssertEqual(padded, 19_200)
        let placement = cursor.place(sampleTime: 77_000_000, frameCount: 512)
        XCTAssertTrue(placement.isContinuous)
        XCTAssertEqual(cursor.framesWritten, 48_000 + 19_200 + 512)
        XCTAssertEqual(cursor.reanchorCount, 1)
    }

    /// Восьмичасовая встреча — наш собственный потолок авто-стопа, и на 48 кГц
    /// это 1.38 млрд кадров. До переполнения 32-битного счётчика (12.4 часа)
    /// остаётся четыре часа запаса, а авто-стоп — это политика, а не гарантия:
    /// зависший `stop()` оставляет писателя работать. Поэтому счётчик
    /// шестидесятичетырёхбитный, и это проверяется, а не подразумевается.
    func testALongMeetingCountsFramesPastTheThirtyTwoBitCeiling() {
        var cursor = CaptureCursor(sampleRate: rate)
        let hourFrames = 3600 * 48_000
        var time: Double = 0
        for _ in 0..<8 {
            _ = cursor.place(sampleTime: time, frameCount: hourFrames)
            time += Double(hourFrames)
        }
        XCTAssertEqual(cursor.framesWritten, 8 * hourFrames)

        for _ in 0..<5 {
            _ = cursor.place(sampleTime: time, frameCount: hourFrames)
            time += Double(hourFrames)
        }
        XCTAssertEqual(cursor.framesWritten, 13 * hourFrames)
        XCTAssertGreaterThan(cursor.framesWritten, Int(Int32.max))
    }

    /// Буфер без часов вообще: пишем в конец, но помечаем, потому что после
    /// такого дорожки уже могут не совпадать сэмпл в сэмпл, и знать об этом
    /// важнее, чем сделать вид, что всё хорошо.
    func testABufferWithNoTimestampIsAppendedButFlagged() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: .nan, frameCount: 512)
        XCTAssertTrue(placement.reanchored)
        XCTAssertEqual(placement.writeFrames, 512)
        XCTAssertEqual(cursor.reanchorCount, 1)
    }

    /// Пауза на десять минут: в файле её нет. Продолжение ложится сразу за уже
    /// записанным — иначе человек, поставивший запись на паузу на обед, получил
    /// бы час тишины посреди встречи (а с потолком в 30 с — сдвиг всего
    /// дальнейшего).
    func testAPauseLeavesNoSilenceInTheRecording() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)

        cursor.detachClock()
        // Часы устройства шли всю паузу.
        let afterPause = cursor.place(sampleTime: 512 + 10 * 60 * rate, frameCount: 512)

        XCTAssertEqual(afterPause.silenceFrames, 0)
        XCTAssertEqual(afterPause.writeFrames, 512)
        XCTAssertFalse(afterPause.reanchored)
        XCTAssertEqual(cursor.framesWritten, 1024)
        XCTAssertEqual(cursor.paddedSilenceFrames, 0)
    }

    /// Пауза — не сбой захвата: счётчик «сколько раз поехали часы» обязан
    /// остаться ответом про здоровье записи.
    func testAPauseIsNotCountedAsAClockProblem() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        cursor.detachClock()
        _ = cursor.place(sampleTime: 99_999, frameCount: 512)
        XCTAssertEqual(cursor.reanchorCount, 0)
    }

    func testAnEmptyBufferChangesNothing() {
        var cursor = CaptureCursor(sampleRate: rate)
        _ = cursor.place(sampleTime: 0, frameCount: 512)
        let placement = cursor.place(sampleTime: 512, frameCount: 0)
        XCTAssertTrue(placement.isEmpty)
        XCTAssertEqual(cursor.framesWritten, 512)
    }
}
