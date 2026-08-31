import XCTest
@testable import PropellerPure

/// # Планировщик, который молча не выдаёт работу
///
/// Замер 31 августа: один человек записывает встречи одиннадцать дней подряд,
/// 29 записей — и ни одного `Transcription.finished` за всё время. Весь его
/// набор сигналов — `Recording.started`, `Recording.finished`, `Notch.bladeStall`
/// и `Notice.shown`. Ни `Pipeline.failed`, ни `Model.*`, ни `Diarize.*`.
/// Приложение сказало ему «записываю» 25 раз и не сказало больше ничего ни разу.
/// Таких — 7 человек и 36 записей без события расшифровки вовсе.
///
/// Два выхода из `pipelineOutlook` отдавали `job = nil` навсегда и беззвучно:
/// залипший флаг звонка и отсутствующий микс. Здесь проверено, что у обоих
/// теперь есть выход, и что простой перестал быть тишиной.
final class PipelineStallTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Row: PipelineCandidate {
        let id: String
        let date: Date
        var status: RecordingStage
        var lastFailure: PipelineFailure?
        var audioAvailable: Bool = true
    }

    // MARK: - Дефект 1а: у флага звонка есть срок

    /// Пропущенный конец звонка. Детектор моргнул, конференс-приложения больше
    /// нет — а флаг остался поднятым. Раньше это значило «архив стоит вечно»:
    /// `meetingDetected` снимается только в `handleCallEnded`, и никто, кроме
    /// него, снять его не мог.
    func testПаузаСнимаетсяКогдаКонференсПриложенийНеОсталось() {
        XCTAssertFalse(
            CallPause.holds(
                detected: true,
                since: t0,
                now: t0.addingTimeInterval(120),
                conferencingAppRunning: false
            ),
            "звонка нет ни в одном приложении — держать паузу не на чем"
        )
    }

    /// Zoom и Slack живут в доке неделями, поэтому у таких людей первая
    /// проверка не сработает никогда: потолок — единственное, что вообще может
    /// сработать. Одиннадцать дней простоя — как раз этот случай.
    func testПаузаСнимаетсяПоПотолкуДажеПриЖивомПриложении() {
        XCTAssertTrue(
            CallPause.holds(
                detected: true,
                since: t0,
                now: t0.addingTimeInterval(CallPause.ceiling - 1),
                conferencingAppRunning: true
            ),
            "настоящая встреча внутри потолка паузу не теряет"
        )
        XCTAssertFalse(
            CallPause.holds(
                detected: true,
                since: t0,
                now: t0.addingTimeInterval(CallPause.ceiling),
                conferencingAppRunning: true
            ),
            "«звонок» длиной в потолок — залипший флаг, а не звонок"
        )
    }

    /// Потолок короче того, что он защищает: сама запись живёт 8 часов
    /// (`AppState.maxRecordingSeconds`). Пауза не обязана жить дольше.
    func testПотолокПаузыКорочеПотолкаЗаписи() {
        XCTAssertLessThan(CallPause.ceiling, 8 * 3600)
        XCTAssertGreaterThan(CallPause.ceiling, 4 * 3600, "настоящая встреча не должна попасть под потолок")
    }

    /// Начало неизвестно — состояние детектора перечитали, а не наблюдали
    /// `.started`. Отмерять потолок не от чего, остаётся проверка приложений.
    func testБезИзвестногоНачалаОстаётсяТолькоПроверкаПриложений() {
        XCTAssertTrue(
            CallPause.holds(detected: true, since: nil, now: t0, conferencingAppRunning: true)
        )
        XCTAssertFalse(
            CallPause.holds(detected: true, since: nil, now: t0, conferencingAppRunning: false)
        )
    }

    func testБезЗвонкаПаузыНет() {
        XCTAssertFalse(
            CallPause.holds(detected: false, since: t0, now: t0, conferencingAppRunning: true)
        )
    }

    // MARK: - Дефект 1б: «нет микса» — это долг, а не пустота

    /// `Recording.finished` уходит раньше, чем микс подтверждён на диске.
    /// Встреча в этом промежутке не причитается ни одной фазе: `owedPhase`
    /// возвращала nil, `owed` оставался нулём, `wakeAt` — nil, таймер не
    /// заводился вовсе. То есть встреча исчезала из очереди навсегда, а стемы
    /// лежали рядом и микс из них собирается.
    func testВстречаБезМиксаСчитаетсяДолгомАНеИсчезает() {
        let outlook = pipelineOutlook(
            from: [Row(id: "a", date: t0, status: .recorded, audioAvailable: false)],
            now: t0
        )
        XCTAssertNil(outlook.job)
        XCTAssertEqual(
            outlook.awaitingAudio, 1,
            "встреча со стемами и без микса обязана быть видимой планировщику"
        )
    }

    /// Аудио убрали ради места у встречи, которая уже расшифрована. Работы по
    /// звуку ей не причитается, и долгом это не является — иначе приложение
    /// вечно пыталось бы пересобрать то, что удалили сознательно.
    func testУдалённоеАудиоПослеРасшифровкиДолгомНеСчитается() {
        let outlook = pipelineOutlook(
            from: [Row(id: "a", date: t0, status: .transcribed, audioAvailable: false)],
            policy: WorkerPolicy(isRecording: false, inCall: false, isThermallyStressed: false,
                                 summariesEnabled: false),
            now: t0
        )
        XCTAssertEqual(outlook.awaitingAudio, 0)
        XCTAssertEqual(outlook.owed, 0)
    }

    /// Терминал — единственный законный конец. Встреча, про которую уже сказано
    /// «пересобирать не из чего», не должна проситься обратно каждый кик.
    func testТерминальнаяВстречаБезАудиоНеПроситсяОбратно() {
        let outlook = pipelineOutlook(
            from: [Row(
                id: "a", date: t0, status: .recorded,
                lastFailure: PipelineFailure(
                    phase: .transcribing,
                    message: MeetingRest.TerminalReason.noSpeech.logMessage,
                    at: t0, kind: .terminal, terminalReason: .noSpeech
                ),
                audioAvailable: false
            )],
            now: t0
        )
        XCTAssertEqual(outlook.awaitingAudio, 0)
    }

    // MARK: - Дефект 2: у планировщика появилась телеметрия

    /// Пауза по политике — не «нечего делать». До 31 августа эти два состояния
    /// были снаружи неотличимы: во всём блоке планировщика не было ни одного
    /// вызова `Analytics`, кроме `noteDayBoundary` и `modelFetch`.
    func testПаузаПоПолитикеОтличимаОтПустогоАрхива() {
        let paused = pipelineOutlook(
            from: [Row(id: "a", date: t0, status: .recorded)],
            policy: WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false),
            now: t0
        )
        XCTAssertEqual(PipelineStall.reason(outlook: paused, workerRunningFor: nil), .policy)

        let done = pipelineOutlook(from: [Row(id: "a", date: t0, status: .summarized)], now: t0)
        XCTAssertNil(
            PipelineStall.reason(outlook: done, workerRunningFor: nil),
            "обработанный архив — не инцидент"
        )
    }

    func testНетАудиоИОжиданиеЛестницыРазличаются() {
        let noAudio = pipelineOutlook(
            from: [Row(id: "a", date: t0, status: .recorded, audioAvailable: false)],
            now: t0
        )
        XCTAssertEqual(PipelineStall.reason(outlook: noAudio, workerRunningFor: nil), .noAudio)

        let waiting = pipelineOutlook(
            from: [Row(
                id: "a", date: t0, status: .recorded,
                lastFailure: PipelineFailure(phase: .transcribing, message: "Ollama недоступен", at: t0)
            )],
            now: t0
        )
        XCTAssertEqual(PipelineStall.reason(outlook: waiting, workerRunningFor: nil), .retryWait)
    }

    /// Идущая фаза — это прогресс, а не простой. Но `kickPipeline` глохнет о
    /// `guard workerTask == nil`, и зависший воркер съедает все кики молча.
    func testДолгаяФазаЗаметнаАКороткаяНет() {
        XCTAssertNil(PipelineStall.reason(outlook: nil, workerRunningFor: 60))
        XCTAssertEqual(
            PipelineStall.reason(outlook: nil, workerRunningFor: PipelineStall.workerSuspectAfter),
            .workerBusy
        )
    }

    /// Выданная работа простоем не считается, что бы ни лежало в архиве.
    func testВыданнаяРаботаНеИнцидент() {
        let running = pipelineOutlook(from: [Row(id: "a", date: t0, status: .recorded)], now: t0)
        XCTAssertNotNil(running.job)
        XCTAssertNil(PipelineStall.reason(outlook: running, workerRunningFor: nil))
    }

    /// Цикл будится раз в пять минут (`PipelineDrain.policyRecheck`). Сигнал на
    /// каждое пробуждение — это вторая `Notch.bladeStall` на 14 тысяч событий.
    func testПростойСообщаетсяОдинРазНаИнцидент() {
        XCTAssertTrue(TelemetryNoise.reportsStall(reason: "policy", lastReported: nil))
        XCTAssertFalse(TelemetryNoise.reportsStall(reason: "policy", lastReported: "policy"))
        XCTAssertTrue(
            TelemetryNoise.reportsStall(reason: "no_audio", lastReported: "policy"),
            "встали уже по другой причине — это другой инцидент"
        )
    }

    // MARK: - Дефект 3: причина отказа расшифровки — измеренная, а не литерал

    /// В общем `catch` у `runASR` стояло
    /// `reason: phase == .diarizing ? "diarize" : "error"`: настоящий текст
    /// ошибки был посчитан строкой рядом, уходил в `recordFailure` и в лог, а в
    /// телеметрию ехало слово «error». Разложить сообщение по корзинам умеет
    /// `PipelineRetry.cause`, которого тот же путь зовёт секундой позже.
    ///
    /// Читается исходник, потому что это правка вызова, а не правила: тестовая
    /// цель `Sources/` не импортирует. Тот же приём, что у
    /// `testBuiltinHotwordsMatchVocabFile`.
    func testОтказРасшифровкиНеОтчитываетсяЛитералом() throws {
        let source = try Self.appStateSource()
        XCTAssertFalse(
            source.contains(#"reason: phase == .diarizing ? "diarize" : "error""#),
            "причина отказа снова захардкожена — верните PipelineRetry.cause(msg)"
        )
        XCTAssertTrue(
            source.contains("PipelineRetry.cause(msg)"),
            "общий catch у runASR обязан отчитываться измеренной корзиной"
        )
    }

    /// Строки, которые этот путь действительно выбрасывает, обязаны
    /// раскладываться по разным корзинам — иначе от правки нет толку.
    func testСтрокиОтказовРасшифровкиРаскладываютсяПоРазнымКорзинам() {
        XCTAssertEqual(PipelineRetry.cause("gigastt недоступен"), "engine_down")
        XCTAssertEqual(PipelineRetry.cause("gigastt не найден в бандле"), "engine_missing")
        XCTAssertEqual(PipelineRetry.cause("Request timed out"), "timeout")
        XCTAssertEqual(PipelineRetry.cause("HTTP 413 payload too large"), "too_large")
        XCTAssertEqual(PipelineRetry.cause("Не хватает места на диске"), "disk")
    }

    private static func appStateSource() throws -> String {
        // …/swift/Tests/MeetingRecorderTests/PipelineStallTests.swift
        let swiftRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // → MeetingRecorderTests/
            .deletingLastPathComponent()   // → Tests/
            .deletingLastPathComponent()   // → swift/
        let appState = swiftRoot.appendingPathComponent("Sources/AppState.swift")
        guard let text = try? String(contentsOf: appState, encoding: .utf8) else {
            throw XCTSkip("Sources/AppState.swift not present (shallow checkout)")
        }
        return text
    }
}
