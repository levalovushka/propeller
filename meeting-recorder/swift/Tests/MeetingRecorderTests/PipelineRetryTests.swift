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

    // MARK: - Украшение, которого не вышло

    /// Встреча, у которой саммари уже написано и читается, а темы не выходят.
    ///
    /// Модель `AppState.finishMetadata`. Ветка «принять и закончить» сторожила
    /// `failure.isTerminal` — и не исполнялась ни разу: терминалом становится
    /// только `kind == .terminal`, а отказ пишется `.transient`. Значит встреча
    /// оставалась на `.saved` навсегда: раз в час поднимала модель на 3,4 ГБ
    /// ради промпта, который уже провалился, и всё это время показывалась как
    /// незаконченная.
    func testТемыПерестаютТребоватьПослеКонечногоЧислаПопыток() {
        var stage = RecordingStage.saved
        var previous: PipelineFailure?
        var acceptedOn: Int?
        // Ограниченный прогон, а не `while stage != .summarized`: тест, который
        // зависает вместо того чтобы покраснеть, не отличим от сломанной сборки.
        for pass in 1...100 where stage != .summarized {
            let failure = PipelineFailure(
                phase: .summarizing, message: "Не удалось определить темы встречи",
                at: t0, previous: previous, kind: .transient
            )
            previous = failure
            if PipelineRetry.acceptsGap(afterAttempt: failure.attempt) {
                stage = .summarized
                acceptedOn = pass
            }
        }
        XCTAssertEqual(stage, .summarized, "встреча с готовым саммари застряла на .saved")
        XCTAssertEqual(acceptedOn, PipelineRetry.cosmeticAttempts)
    }

    func testОтказНаТемахТерминальнымНеСтановитсяНикогда() {
        // То, чего ждал прежний сторож. Он ждал этого зря — и на тринадцатой
        // попытке тоже.
        var failure = PipelineFailure(
            phase: .summarizing, message: "Не удалось определить темы встречи",
            at: t0, kind: .transient
        )
        for attempt in 2...13 {
            failure = PipelineFailure(
                phase: .summarizing, message: failure.message,
                at: t0, previous: failure, kind: .transient
            )
            XCTAssertEqual(failure.attempt, attempt)
            XCTAssertFalse(failure.isTerminal, "попытка \(attempt)")
        }
    }

    func testПотолокНеРаспространяетсяНаНастоящуюРаботу() {
        // Потолок принадлежит украшению, а не лестнице. Расшифровка и саммари —
        // то, ради чего встреча существует, и сдаваться на них по счётчику
        // значит вернуть тупик, который убирали.
        XCTAssertFalse(PipelineRetry.acceptsGap(afterAttempt: 2))
        for phase in PipelineActivity.Phase.allCases {
            XCTAssertNotNil(
                PipelineRetry.nextAttempt(
                    kind: .transient, attempt: 99, phase: phase, after: t0
                ),
                "\(phase): у настоящей работы потолка попыток нет"
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

    // MARK: - Корзина причины

    /// Строки взяты из кода, который их бросает, а не придуманы: если формулировку
    /// в пайплайне поменяют, этот тест обязан покраснеть — иначе корзина молча
    /// станет `other`, и телеметрия будет говорить «что-то случилось».
    func testEachRealFailureMessageLandsInItsOwnBucket() {
        let cases: [(String, String)] = [
            ("gigastt недоступен — файл не найден", "engine_missing"),
            ("Бинарник gigastt не найден в бандле приложения.", "engine_missing"),
            ("gigastt недоступен — не удалось запустить движок речи.", "engine_down"),
            ("gigastt недоступен", "engine_down"),
            ("не удалось подключиться", "engine_down"),
            ("gigastt не вернул сегменты (тишина или слишком короткий фрагмент?).", "no_speech"),
            ("В записи не нашлось речи", "no_speech"),
            ("не удалось разобрать ответ gigastt", "parse"),
            ("Транскрипт не найден на диске", "transcript_missing"),
            ("Не удалось прочитать транскрипт", "transcript_missing"),
            ("Не удалось определить темы встречи", "topics"),
            ("Фаза не продвинула стадию", "stalled"),
            ("тело запроса слишком большое", "too_large"),
            ("HTTP 413", "too_large"),
            ("файл слишком маленький (128 байт)", "audio_small"),
            ("Модель ушла в рассуждения", "thinking"),
            ("Запрос не успело завершиться: таймаут", "timeout"),
            ("HTTP 503", "server"),
            ("The Internet connection appears to be offline.", "network"),
            ("Недостаточно места на диске", "disk"),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(
                PipelineRetry.cause(message), expected,
                "«\(message)» ожидалось в корзине \(expected)"
            )
        }
    }

    /// Порядок таблицы — часть смысла, а не оформление. 413 это и код ответа
    /// сервера, и наш просчёт чанкера; если `server` окажется выше, мы будем
    /// чинить сеть вместо чанкера.
    func testSpecificBucketsWinOverGeneralOnes() {
        XCTAssertEqual(PipelineRetry.cause("HTTP 413 too large"), "too_large")
        XCTAssertEqual(
            PipelineRetry.cause("gigastt недоступен — файл не найден"), "engine_missing",
            "«недоступен» здесь есть, но чинить надо установку"
        )
    }

    /// Незнакомое не притворяется знакомым: `other` — честный ответ, и по его
    /// доле в телеметрии видно, что таблица отстала от кода.
    func testAnUnknownMessageIsOtherRatherThanAGuess() {
        XCTAssertEqual(PipelineRetry.cause("Kernel panic in the espresso machine"), "other")
        XCTAssertEqual(PipelineRetry.cause(""), "other")
    }

    /// Корзина и вина независимы: одна отвечает «что случилось», другая «ждать ли».
    func testCauseDoesNotDecideWhetherToRetry() {
        XCTAssertEqual(PipelineRetry.classify("HTTP 413"), .ourFault)
        XCTAssertEqual(PipelineRetry.cause("HTTP 413"), "too_large")
        XCTAssertEqual(PipelineRetry.classify("gigastt недоступен"), .transient)
        XCTAssertEqual(PipelineRetry.cause("gigastt недоступен"), "engine_down")
    }
}
