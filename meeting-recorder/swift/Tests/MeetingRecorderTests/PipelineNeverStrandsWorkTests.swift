import XCTest
@testable import PropellerPure

/// The one promise the whole catch-up rests on: **owed work always has a way
/// back.** Either something is running, or there is a deadline to wake at, or
/// the pipeline is waiting on an event that is actually observed (a call ending,
/// a stopped recording, a Mac that cooled down).
///
/// Every stranded-meeting bug this app has had was a hole in exactly that
/// sentence, so it is checked here as a property over randomised archives rather
/// than as a handful of examples.
final class PipelineNeverStrandsWorkTests: XCTestCase {

    private struct Row: PipelineCandidate {
        let id: String
        let date: Date
        var status: RecordingStage
        var lastFailure: PipelineFailure?
        var audioAvailable: Bool
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Deterministic pseudo-random archives — a fixed seed, so a failure here is
    /// reproducible instead of a story about a build that went red once.
    private func archives(count: Int) -> [[Row]] {
        var seed: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let stages = RecordingStage.allCases
        let messages = [
            "Ollama недоступен",            // переживаемое
            "gigastt HTTP 413",             // наш баг
            "в записи не нашлось речи",     // терминал (объявляется явно, ниже)
        ]
        return (0..<count).map { _ in
            (0..<next(6)).map { i in
                let failure: PipelineFailure? = {
                    switch next(3) {
                    case 0: return nil
                    default:
                        let pick = next(3)
                        var f = PipelineFailure(
                            phase: PipelineActivity.Phase.allCases[next(4)],
                            message: messages[pick],
                            at: t0.addingTimeInterval(-Double(next(600))),
                            // Терминал объявляет вызывающий, а не текст — как в
                            // приложении.
                            kind: pick == 2 ? .terminal : nil,
                            terminalReason: pick == 2 ? .noSpeech : nil
                        )
                        // Sometimes escalate it a few times, to reach the
                        // attempts-exhausted shape too.
                        for _ in 0..<next(6) {
                            f = PipelineFailure(
                                phase: PipelineActivity.Phase(rawValue: f.phase) ?? .summarizing,
                                message: f.message, at: f.at, previous: f
                            )
                        }
                        return f
                    }
                }()
                return Row(
                    id: "r\(i)",
                    date: t0.addingTimeInterval(-Double(next(100_000))),
                    status: stages[next(stages.count)],
                    lastFailure: failure,
                    audioAvailable: next(4) > 0
                )
            }
        }
    }

    private var policies: [WorkerPolicy] {
        [
            .unrestricted,
            WorkerPolicy(isRecording: true, inCall: false, isThermallyStressed: false),
            WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false),
            WorkerPolicy(isRecording: false, inCall: false, isThermallyStressed: true),
            WorkerPolicy(
                isRecording: false, inCall: false, isThermallyStressed: false,
                summariesEnabled: false
            ),
        ]
    }

    // MARK: - The property

    func testOwedWorkAlwaysHasAWayBack() {
        for archive in archives(count: 400) {
            for policy in policies {
                let outlook = pipelineOutlook(from: archive, policy: policy, now: t0)
                guard outlook.owed > 0 else { continue }
                XCTAssertTrue(
                    outlook.job != nil || outlook.wakeAt != nil || outlook.pausedByPolicy,
                    """
                    \(outlook.owed) meeting(s) owed with nothing running, no deadline \
                    and no policy waiting on an event — that archive would sit \
                    unfinished until the next launch. policy: \(policy)
                    """
                )
            }
        }
    }

    /// And the same after a drain stops, which is the moment the app decides
    /// whether to set a timer at all.
    func testAfterEveryDrainStopOwedWorkStillHasAWayBack() {
        let job = PipelineJob(recordingID: "r0", phase: .summarizing)
        let stops: [PipelineDrain.Stop] = [.finished, .blocked(job), .cancelled, .stalled(job)]
        for archive in archives(count: 200) {
            for policy in policies {
                let outlook = pipelineOutlook(from: archive, policy: policy, now: t0)
                for stop in stops {
                    let plan = PipelineDrain.plan(
                        after: stop, outlook: outlook, blockedStreak: 0, now: t0
                    )
                    guard outlook.owed > 0 else { continue }
                    // `.stalled` parks the offending job; anything else owed must
                    // still be reachable.
                    if case .stalled = stop, outlook.owed == 1 { continue }
                    XCTAssertTrue(
                        plan.wakeAt != nil || outlook.job != nil,
                        "\(stop) left \(outlook.owed) owed with no deadline"
                    )
                }
            }
        }
    }

    /// The mirror image, and just as important for the battery: a finished
    /// archive must not keep a timer alive.
    func testAFinishedArchiveSchedulesNothing() {
        let done = [
            Row(id: "a", date: t0, status: .summarized, lastFailure: nil, audioAvailable: true),
            Row(id: "b", date: t0, status: .recording, lastFailure: nil, audioAvailable: true),
        ]
        let outlook = pipelineOutlook(from: done, policy: .unrestricted, now: t0)
        XCTAssertEqual(outlook, .nothingToDo)
        for stop in [PipelineDrain.Stop.finished, .cancelled] {
            let plan = PipelineDrain.plan(after: stop, outlook: outlook, blockedStreak: 0, now: t0)
            XCTAssertNil(plan.wakeAt, "\(stop) scheduled a wakeup for an empty queue")
        }
    }

    /// Встреча, которой уже нечего дать, не держит таймеров.
    ///
    /// Раньше сюда приходили и «кончились попытки»: цикл `while !isTerminal`
    /// повторял отказ, пока приложение не сдастся. Лестница больше не кончается,
    /// поэтому такого цикла не существует — и это ровно то, ради чего всё
    /// делалось. Терминал остался один: входа нет.
    func testВстречеБезВходаТаймерыНеНужны() {
        let failure = PipelineFailure(
            phase: .transcribing, message: "Аудио удалено — расшифровывать нечего",
            at: t0, kind: .terminal
        )
        let archive = [Row(id: "a", date: t0, status: .recorded, lastFailure: failure, audioAvailable: false)]
        let outlook = pipelineOutlook(from: archive, policy: .unrestricted, now: t0)
        XCTAssertEqual(outlook, .nothingToDo)
    }

    /// А сколько бы раз ни падало переживаемое — работа остаётся причитающейся.
    func testСтоПопытокПодрядНеДелаютВстречуБезнадёжной() {
        var failure = PipelineFailure(phase: .summarizing, message: "Ollama недоступен", at: t0)
        for _ in 0..<100 {
            failure = PipelineFailure(
                phase: .summarizing, message: "Ollama недоступен", at: t0, previous: failure
            )
        }
        XCTAssertEqual(failure.attempt, 101)
        XCTAssertFalse(failure.isTerminal)
        let archive = [Row(id: "a", date: t0, status: .saved, lastFailure: failure, audioAvailable: true)]
        let outlook = pipelineOutlook(from: archive, policy: .unrestricted, now: t0)
        XCTAssertNotEqual(outlook, .nothingToDo, "приложение всё ещё должно это саммари")
    }

    // MARK: - The provider ladder

    func testBlockedOnAProviderAlwaysSchedulesAnotherLook() {
        let archive = [Row(id: "a", date: t0, status: .saved, lastFailure: nil, audioAvailable: true)]
        let outlook = pipelineOutlook(from: archive, policy: .unrestricted, now: t0)
        var streak = 0
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            let plan = PipelineDrain.plan(
                after: .blocked(PipelineJob(recordingID: "a", phase: .summarizing)),
                outlook: outlook, blockedStreak: streak, now: t0
            )
            streak = plan.blockedStreak
            waits.append(plan.wakeAt!.timeIntervalSince(t0))
        }
        XCTAssertEqual(waits, [60, 300, 900, 1800, 1800])
        XCTAssertEqual(streak, 5)
    }

    /// A retry deadline that comes sooner than the next provider check wins —
    /// waiting half an hour to retry something due in 20 seconds would be the
    /// ladder making things worse.
    func testTheSoonerOfTheTwoDeadlinesWins() {
        let archive = [
            Row(id: "a", date: t0, status: .saved, lastFailure: nil, audioAvailable: true),
            Row(id: "b", date: t0.addingTimeInterval(-60), status: .saved,
                lastFailure: PipelineFailure(phase: .summarizing, message: "HTTP 503", at: t0),
                audioAvailable: true),
        ]
        let outlook = pipelineOutlook(from: archive, policy: .unrestricted, now: t0)
        let plan = PipelineDrain.plan(
            after: .blocked(PipelineJob(recordingID: "a", phase: .summarizing)),
            outlook: outlook, blockedStreak: 3, now: t0
        )
        XCTAssertEqual(
            plan.wakeAt, t0.addingTimeInterval(20),
            "a retry due in 20s must not wait out the half-hour provider ladder"
        )
    }

    func testAFinishedDrainForgetsTheProviderLadder() {
        let plan = PipelineDrain.plan(
            after: .finished, outlook: .nothingToDo, blockedStreak: 4, now: t0
        )
        XCTAssertEqual(plan.blockedStreak, 0)
    }

    func testAPausedDrainKeepsTheLadderWhereItWas() {
        let plan = PipelineDrain.plan(
            after: .cancelled, outlook: .nothingToDo, blockedStreak: 2, now: t0
        )
        XCTAssertEqual(plan.blockedStreak, 2, "a call is not evidence about the provider")
    }

    /// A pause waits on an event — a call ending, a Mac cooling down — but not
    /// only on one. If that notification never arrives the archive still gets
    /// looked at, minutes later rather than never.
    ///
    /// `outlook.wakeAt` is only retry deadlines, so a kick that schedules from
    /// outlook alone would leave nil here and strand the archive on a missed
    /// hang-up. AppState must go through `PipelineDrain.plan`.
    func testAPolicyPauseStillGetsADeadline() {
        let archive = [Row(id: "a", date: t0, status: .saved, lastFailure: nil, audioAvailable: true)]
        let inCall = WorkerPolicy(isRecording: false, inCall: true, isThermallyStressed: false)
        let outlook = pipelineOutlook(from: archive, policy: inCall, now: t0)
        XCTAssertTrue(outlook.pausedByPolicy)
        XCTAssertNil(outlook.wakeAt, "outlook itself only carries retry deadlines")
        let plan = PipelineDrain.plan(after: .finished, outlook: outlook, blockedStreak: 0, now: t0)
        XCTAssertEqual(plan.wakeAt, t0.addingTimeInterval(PipelineDrain.policyRecheck))
    }

    // MARK: - How much work a summary actually is

    func testSummaryWorkAndTheStageReconcilerAgree() {
        for hasRecap in [true, false] {
            for hasMetadata in [true, false] {
                let work = SummaryWork.needed(hasRecapFile: hasRecap, hasMetadata: hasMetadata)
                let reconciled = SummaryStageReconciler.reconciled(
                    current: .saved, hasRecapFile: hasRecap, hasMetadata: hasMetadata
                )
                XCTAssertEqual(
                    work == .nothing, reconciled == .summarized,
                    "recap: \(hasRecap), metadata: \(hasMetadata) — the reconciler and the "
                        + "phase disagree about whether this meeting is done"
                )
            }
        }
    }

    /// The expensive mistake this replaced: an archive of summaries missing their
    /// topics was re-summarised from scratch, meeting by meeting.
    func testAMeetingWithASummaryButNoTopicsOnlyNeedsTheShortPass() {
        XCTAssertEqual(
            SummaryWork.needed(hasRecapFile: true, hasMetadata: false), .metadataOnly
        )
        XCTAssertEqual(
            SummaryWork.needed(hasRecapFile: false, hasMetadata: false), .fullRecap
        )
    }
}

// MARK: - I13. Ни один отказ не требует человека

/// Продолжение I12 («есть работа ⇒ есть дедлайн») и главное обещание
/// `design/no-dead-ends.md`: у встречи не бывает состояния, из которого путь
/// только через клик. Проверяется свойством на случайных отказах — по той же
/// причине, по которой I12: каждая застрявшая встреча в истории этого приложения
/// была дыркой ровно в одном предложении.
final class NoDeadEndInvariantTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func failures(count: Int) -> [PipelineFailure] {
        var seed: UInt64 = 0xA1B2C3D4
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let messages = ["Ollama недоступен", "gigastt HTTP 413", "NSXPCConnectionInterrupted",
                        "timed out", "Аудио удалено", "В записи не нашлось речи"]
        return (0..<count).map { _ in
            let terminal = next(4) == 0
            let reason = MeetingRest.TerminalReason.allCases[next(MeetingRest.TerminalReason.allCases.count)]
            var f = PipelineFailure(
                phase: PipelineActivity.Phase.allCases[next(4)],
                message: messages[next(messages.count)],
                at: t0.addingTimeInterval(-Double(next(6000))),
                kind: terminal ? .terminal : nil,
                terminalReason: terminal ? reason : nil
            )
            for _ in 0..<next(20) {
                f = PipelineFailure(
                    phase: PipelineActivity.Phase(rawValue: f.phase) ?? .summarizing,
                    message: f.message, at: f.at, previous: f,
                    kind: terminal ? .terminal : nil,
                    terminalReason: terminal ? reason : nil
                )
            }
            return f
        }
    }

    func testВстречаВсегдаЛибоЖдётЛибоЗакончена() {
        // Третьего состояния нет — тип не даёт его выразить, а этот тест проверяет,
        // что и выводится оно всегда одним из двух, на любом входе.
        for failure in failures(count: 300) {
            for stage in RecordingStage.allCases {
                for working in [false, true] {
                    for summaries in [false, true] {
                        for modelReady in [false, true] {
                            let rest = MeetingRest.of(
                                stage: stage, failure: failure, isWorkingOnIt: working,
                                summariesEnabled: summaries, summaryModelReady: modelReady
                            )
                            switch rest {
                            case .waiting: XCTAssertTrue(rest.owesWork)
                            case .done:    XCTAssertFalse(rest.owesWork)
                            }
                        }
                    }
                }
            }
        }
    }

    func testОжиданиеВсегдаПодкрепленоЗапланированнойПопыткой() {
        // «Ждём» без назначенной попытки — это тупик, только вежливо
        // сформулированный.
        for failure in failures(count: 300) where !failure.isTerminal {
            XCTAssertNotNil(failure.nextAttemptAt, failure.message)
        }
    }

    func testТерминалВсегдаНазываетПричину() {
        // Иначе карточке нечего сказать, и «дальше нечего делать» превращается в
        // молчание, которое человек прочитает как поломку.
        for failure in failures(count: 300) where failure.isTerminal {
            XCTAssertNotNil(failure.terminalReason)
            let rest = MeetingRest.of(
                stage: .recorded, failure: failure, isWorkingOnIt: false,
                summariesEnabled: true, summaryModelReady: true
            )
            if case .done(let reason) = rest {
                XCTAssertEqual(reason, failure.terminalReason)
            } else {
                XCTFail("терминальный отказ обязан читаться как законченная встреча")
            }
        }
    }

    func testНиОдноСостояниеПокояНеПроситНажатий() {
        // Раскрытие — утверждение о глубине. Ни одно из них не имеет права быть
        // просьбой: ни «Повторить», ни «Попробуйте», ни «Не удалось».
        let forbidden = ["Повтор", "Попроб", "Не удалось", "Ошибка", "ажмите"]
        var seen: Set<String> = []
        for wait in MeetingRest.WaitReason.allCases {
            if let text = MeetingRest.waiting(wait).disclosure { seen.insert(text) }
        }
        for done in MeetingRest.TerminalReason.allCases {
            if let text = MeetingRest.done(done).disclosure { seen.insert(text) }
        }
        XCTAssertFalse(seen.isEmpty)
        for text in seen {
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "«\(text)» содержит «\(word)»")
            }
        }
    }

    func testЗаконченнаяВстречаМолчитАНеОбъявляетУспех() {
        // «Готово!» — такой же шум, как «Ошибка»: об этом говорит сам факт, что
        // саммари есть.
        XCTAssertNil(MeetingRest.done(.complete).disclosure)
        XCTAssertNil(MeetingRest.waiting(.queued).disclosure)
        XCTAssertNil(MeetingRest.waiting(.working).disclosure)
    }

    func testСВыключеннымСаммариВстречаЗаканчиваетсяНаТранскрипте() {
        // Это не «недоделано»: дно лестницы просто другое.
        let rest = MeetingRest.of(
            stage: .saved, failure: nil, isWorkingOnIt: false,
            summariesEnabled: false, summaryModelReady: false
        )
        XCTAssertEqual(rest, .done(.summariesOff))
        XCTAssertFalse(rest.owesWork)
    }

    func testБезМоделиВстречаЖдётМодельАНеЧеловека() {
        let rest = MeetingRest.of(
            stage: .saved, failure: nil, isWorkingOnIt: false,
            summariesEnabled: true, summaryModelReady: false
        )
        XCTAssertEqual(rest, .waiting(.model))
        XCTAssertTrue(rest.owesWork)
    }

    func testДоТранскриптаМодельНикогоНеДержит() {
        // Модель нужна только саммари: свежая запись без модели ждёт очереди, а
        // не загрузки — иначе строка врёт о том, чего она ждёт.
        let rest = MeetingRest.of(
            stage: .recorded, failure: nil, isWorkingOnIt: false,
            summariesEnabled: true, summaryModelReady: false
        )
        XCTAssertEqual(rest, .waiting(.queued))
    }
}
