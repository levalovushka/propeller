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

    func testThingsOnlyAPersonCanFixArePermanent() {
        let hopeless = [
            "Аудиофайл не найден — нельзя расшифровать.",
            "Транскрипт не найден на диске",
            "Нет транскрипта для сохранения",
            "Саммари пропущено — пустой транскрипт",
            "LLM HTTP 413: body too large",
            "Расшифровка отменена — мало места на диске.",
            "qwen3.5:4b — модель ушла в рассуждения и не выдала конспект",
            "You don't have permission to save the file",
        ]
        for message in hopeless {
            XCTAssertEqual(PipelineRetry.classify(message), .permanent, message)
        }
    }

    /// "недоступен" appears in both worlds, so order decides. A missing file
    /// must not read as a transport problem just because the sentence mentions
    /// the sidecar.
    func testAMissingFileWinsOverAnUnavailableService() {
        XCTAssertEqual(
            PipelineRetry.classify("gigastt недоступен: файл не найден"),
            .permanent
        )
    }

    /// An error nobody has seen yet gets the benefit of the doubt — but only
    /// two extra tries' worth of it.
    func testAnUnrecognisedErrorIsRetriedButNotForever() {
        XCTAssertEqual(PipelineRetry.classify("NSXPCConnectionInterrupted (4097)"), .transient)
    }

    // MARK: - The schedule

    func testTheFirstRetryIsAlmostImmediateAndTheLastIsPatient() {
        let phase = PipelineActivity.Phase.summarizing
        let delays = (1...4).map {
            PipelineRetry.nextAttempt(kind: .transient, attempt: $0, phase: phase, after: t0)?
                .timeIntervalSince(t0)
        }
        XCTAssertEqual(delays, [20, 60, 300, 1200])
    }

    func testAttemptsRunOutAndTheMeetingBecomesTheUsersProblem() {
        let phase = PipelineActivity.Phase.summarizing
        XCTAssertNotNil(PipelineRetry.nextAttempt(kind: .transient, attempt: 4, phase: phase, after: t0))
        XCTAssertNil(
            PipelineRetry.nextAttempt(kind: .transient, attempt: 5, phase: phase, after: t0),
            "the fifth failure is the one worth telling someone about"
        )
    }

    /// Re-running ASR is minutes of CPU; re-asking a model that was still
    /// loading is seconds. They should not get the same patience.
    func testTranscriptionGivesUpSoonerThanTheSummary() {
        XCTAssertLessThan(
            PipelineRetry.maxAttempts(for: .transcribing),
            PipelineRetry.maxAttempts(for: .summarizing)
        )
        XCTAssertNil(
            PipelineRetry.nextAttempt(kind: .transient, attempt: 3, phase: .transcribing, after: t0)
        )
    }

    func testPermanentFailuresAreNeverRescheduled() {
        for phase in PipelineActivity.Phase.allCases {
            XCTAssertNil(
                PipelineRetry.nextAttempt(kind: .permanent, attempt: 1, phase: phase, after: t0),
                "\(phase)"
            )
        }
    }

    func testProviderRecheckWalksOutAndStopsGrowing() {
        let waits = (1...6).map { PipelineRetry.providerRecheck(afterBlockedStreak: $0) }
        XCTAssertEqual(waits, [60, 300, 900, 1800, 1800, 1800])
    }

    // MARK: - Failures escalate on the recording

    func testRepeatedFailuresOfTheSamePhaseEscalate() {
        var failure = PipelineFailure(phase: .summarizing, message: "Ollama недоступен", at: t0)
        XCTAssertEqual(failure.attempt, 1)
        XCTAssertEqual(failure.kind, .transient)
        XCTAssertFalse(failure.needsAttention)

        for attempt in 2...4 {
            failure = PipelineFailure(
                phase: .summarizing, message: "Ollama недоступен", at: t0, previous: failure
            )
            XCTAssertEqual(failure.attempt, attempt)
            XCTAssertFalse(failure.needsAttention, "attempt \(attempt) should still be ours to fix")
        }
        failure = PipelineFailure(
            phase: .summarizing, message: "Ollama недоступен", at: t0, previous: failure
        )
        XCTAssertEqual(failure.attempt, 5)
        XCTAssertTrue(failure.needsAttention, "after five tries the user gets to know")
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

    func testAPermanentFailureIsShownOnTheFirstTry() {
        let failure = PipelineFailure(
            phase: .transcribing, message: "Аудиофайл не найден — нельзя расшифровать.", at: t0
        )
        XCTAssertEqual(failure.attempt, 1)
        XCTAssertTrue(failure.needsAttention)
        XCTAssertTrue(failure.blocks(at: t0.addingTimeInterval(86_400)))
    }

    func testWaitingIsNotTheSameAsBroken() {
        let failure = PipelineFailure(phase: .summarizing, message: "HTTP 503", at: t0)
        XCTAssertTrue(failure.blocks(at: t0.addingTimeInterval(5)))
        XCTAssertFalse(failure.blocks(at: t0.addingTimeInterval(25)), "the deadline passed")
        XCTAssertFalse(failure.needsAttention, "a wait is not something to report")
    }

    // MARK: - Old archives

    /// An index written by a build that had no retry plan must decode as
    /// "parked, waiting for the user" — the behaviour that build had. Waking up
    /// and re-running ASR on a meeting someone already gave up on is worse than
    /// leaving it alone.
    func testAnIndexFromAnOlderBuildDecodesAsParked() throws {
        let json = """
        {"phase":"transcribing","message":"gigastt недоступен","at":760000000}
        """.data(using: .utf8)!
        let failure = try JSONDecoder().decode(PipelineFailure.self, from: json)
        XCTAssertEqual(failure.attempt, 1)
        XCTAssertEqual(failure.kind, .permanent)
        XCTAssertTrue(failure.needsAttention)
    }

    func testAFailureSurvivesARoundTrip() throws {
        let original = PipelineFailure(phase: .saving, message: "HTTP 500", at: t0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PipelineFailure.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.nextAttemptAt, original.nextAttemptAt)
    }
}
