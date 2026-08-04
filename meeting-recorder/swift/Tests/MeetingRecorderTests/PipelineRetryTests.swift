import XCTest
@testable import PropellerPure

/// The rules that decide whether the user ever hears about a failure.
///
/// Named after what a person would see, because that is the only thing these
/// rules are for: "the sidecar was not up yet" must end with a finished meeting
/// and no message, and "the audio file is gone" must end with a button.
final class PipelineRetryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - What deserves another try

    func testThingsThatFixThemselvesAreTransient() {
        let selfHealing = [
            "gigastt недоступен",
            "Ollama недоступен",
            "The request timed out",
            "Саммари не успело за 10 минут — модель перегружена",
            "Could not connect to the server",
            "Не удалось подключиться к 127.0.0.1:11434",
            "The network connection was lost",
            "HTTP 503: service unavailable",
            "LLM HTTP 429: rate limit",
            "HTTP 500: internal error",
            "socket is not connected",
        ]
        for message in selfHealing {
            XCTAssertEqual(PipelineRetry.classify(message), .transient, message)
        }
    }

    func testОшибкиНашегоЖеКодаПомечаютсяКакНаши() {
        // Их всё равно повторяем — но считаем: баг, который воспроизводится
        // только на чужой машине, иначе до нас не доходит.
        let ours = [
            "LLM HTTP 413: body too large",
            "gigastt HTTP 413: тело запроса слишком большое",
            "qwen3.5:4b — модель ушла в рассуждения и не выдала конспект",
        ]
        for message in ours {
            XCTAssertEqual(PipelineRetry.classify(message), .ourFault, message)
        }
    }

    func testПоТекстуОшибкиТерминалНеОбъявляетсяНикогда() {
        // «gigastt недоступен: файл не найден» — это сломанная установка, а не
        // пропавшая запись. Припарковать встречу навсегда по подстроке — ровно
        // тот тупик, который мы и убираем: терминал объявляет только тот, кто
        // сам посмотрел на вход.
        let temptations = [
            "gigastt недоступен: файл не найден",
            "Аудиофайл не найден — нельзя расшифровать.",
            "Транскрипт не найден на диске",
            "You don't have permission to save the file",
            "no space left on device",
            "NSXPCConnectionInterrupted (4097)",
        ]
        for message in temptations {
            XCTAssertNotEqual(PipelineRetry.classify(message), .terminal, message)
        }
    }

    // MARK: - The schedule

    func testПервыйПовторПочтиСразуАДальшеВсёТерпеливее() {
        let phase = PipelineActivity.Phase.summarizing
        let delays = (1...5).map {
            PipelineRetry.nextAttempt(kind: .transient, attempt: $0, phase: phase, after: t0)?
                .timeIntervalSince(t0)
        }
        XCTAssertEqual(delays, [20, 60, 300, 1200, 3600])
    }

    func testПопыткиНеКончаютсяНикогда() {
        // Счётчик попыток и был главным источником тупиков: пока он есть, у
        // приложения существует момент, когда оно сдаётся и просит человека.
        let phase = PipelineActivity.Phase.summarizing
        for attempt in [6, 42, 1000] {
            XCTAssertEqual(
                PipelineRetry.nextAttempt(kind: .transient, attempt: attempt, phase: phase, after: t0)?
                    .timeIntervalSince(t0),
                3600,
                "попытка \(attempt) должна быть назначена — через час, но назначена"
            )
        }
    }

    func testВсеФазыОдинаковоНеСдаются() {
        for phase in PipelineActivity.Phase.allCases {
            for kind in [FailureKind.transient, .ourFault] {
                XCTAssertNotNil(
                    PipelineRetry.nextAttempt(kind: kind, attempt: 9, phase: phase, after: t0),
                    "\(phase) / \(kind)"
                )
            }
        }
    }

    func testТолькоТерминалНеПланируетсяЗаново() {
        // Единственный случай, когда работы больше нет: входа не существует.
        for phase in PipelineActivity.Phase.allCases {
            XCTAssertNil(
                PipelineRetry.nextAttempt(kind: .terminal, attempt: 1, phase: phase, after: t0),
                "\(phase)"
            )
        }
    }

    func testProviderRecheckWalksOutAndStopsGrowing() {
        let waits = (1...6).map { PipelineRetry.providerRecheck(afterBlockedStreak: $0) }
        XCTAssertEqual(waits, [60, 300, 900, 1800, 1800, 1800])
    }

    // MARK: - Failures escalate on the recording

    func testПовторыОднойФазыКопятсяНоНикогдаНеСтановятсяЗаботойЧеловека() {
        var failure = PipelineFailure(phase: .summarizing, message: "Ollama недоступен", at: t0)
        XCTAssertEqual(failure.kind, .transient)
        for attempt in 2...12 {
            failure = PipelineFailure(
                phase: .summarizing, message: "Ollama недоступен", at: t0, previous: failure
            )
            XCTAssertEqual(failure.attempt, attempt)
            XCTAssertFalse(
                failure.isTerminal,
                "попытка \(attempt): пайплайн всё ещё должен эту работу"
            )
        }
    }

    /// A meeting that failed ASR last week and its summary today is not on its
    /// second summary attempt.
    func testADifferentPhaseStartsCountingAgain() {
        let asr = PipelineFailure(phase: .transcribing, message: "gigastt недоступен", at: t0)
        let recap = PipelineFailure(
            phase: .summarizing, message: "Ollama недоступен", at: t0, previous: asr
        )
        XCTAssertEqual(recap.attempt, 1)
    }

    func testТерминалОбъявляетТотКтоПосмотрелНаВход() {
        // Не текст сообщения, а вызывающий: он единственный знает, что аудио
        // действительно нет.
        let failure = PipelineFailure(
            phase: .transcribing, message: "Аудио удалено — расшифровывать нечего",
            at: t0, kind: .terminal
        )
        XCTAssertTrue(failure.isTerminal)
        XCTAssertTrue(failure.blocks(at: t0.addingTimeInterval(86_400)))
        // А та же строка без явного `kind` — просто повод попробовать ещё раз.
        XCTAssertFalse(
            PipelineFailure(phase: .transcribing, message: "Аудио удалено", at: t0).isTerminal
        )
    }

    func testWaitingIsNotTheSameAsBroken() {
        let failure = PipelineFailure(phase: .summarizing, message: "HTTP 503", at: t0)
        XCTAssertTrue(failure.blocks(at: t0.addingTimeInterval(5)))
        XCTAssertFalse(failure.blocks(at: t0.addingTimeInterval(25)), "the deadline passed")
        XCTAssertFalse(failure.isTerminal, "ожидание — это не конец")
    }

    // MARK: - Old archives

    /// Индекс от старой сборки распарковывается: кнопки «Повторить» больше нет,
    /// значит «ждёт человека» читается единственным честным способом — «мы всё
    /// ещё должны эту работу». Это и есть миграция красных встреч.
    func testАрхивСтаройСборкиРаспарковывается() throws {
        let noKind = """
        {"phase":"transcribing","message":"gigastt недоступен","at":760000000}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(PipelineFailure.self, from: noKind)
        XCTAssertEqual(old.kind, .transient)
        XCTAssertFalse(old.isTerminal, "красная встреча из 1.15 обязана вернуться в очередь")

        let parked = """
        {"phase":"summarizing","message":"LLM недоступен","at":760000000,"attempt":5,"kind":"permanent"}
        """.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(PipelineFailure.self, from: parked)
        XCTAssertEqual(migrated.kind, .transient)
        XCTAssertFalse(migrated.isTerminal)
        XCTAssertEqual(migrated.attempt, 5, "счётчик читается, просто больше ничем не грозит")
    }

    func testAFailureSurvivesARoundTrip() throws {
        let original = PipelineFailure(phase: .saving, message: "HTTP 500", at: t0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PipelineFailure.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.nextAttemptAt, original.nextAttemptAt)
    }
}
