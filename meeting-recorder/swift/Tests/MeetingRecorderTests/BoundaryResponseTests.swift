import XCTest
@testable import PropellerPure

/// The outside world, played back from recorded answers.
///
/// Every fixture here is a real incident from STATE.md. Before this, reaching
/// any of them meant a live sidecar, a live model and — for the 413 — a
/// 43-minute meeting. Now they run in microseconds.
final class BoundaryResponseTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MeetingRecorderTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/boundaries/\(name)")
        return try Data(contentsOf: url)
    }

    // MARK: - ASR sidecar

    func testReadsSegmentsWithTimings() throws {
        let result = BoundaryResponses.readASR(status: 200, data: try fixture("asr-ok.json"))
        guard case .success(let transcription) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(transcription.segments.count, 2)
        XCTAssertEqual(transcription.segments[0].text, "Это запись небольшой встречи.")
        // Zero-length segments are real and must survive — trimming them would
        // lose a word from the transcript.
        XCTAssertEqual(transcription.segments[1].text, "хорошо")
    }

    /// The incident: a ~43-minute meeting (~79 MiB) hit the sidecar's default
    /// body limit. Audio was fine, transcript was silently lost. The remedy is
    /// chunking, so this failure must stay distinguishable from a generic one.
    func testTooLargeIsItsOwnFailureNotJustABadStatus() throws {
        let result = BoundaryResponses.readASR(status: 413, data: try fixture("asr-413.txt"))
        guard case .failure(let failure) = result else { return XCTFail("should not parse") }
        XCTAssertEqual(failure, .tooLarge(status: 413))
    }

    func testSidecarErrorEnvelopeIsSurfacedWithItsMessage() throws {
        let result = BoundaryResponses.readASR(status: 400, data: try fixture("asr-error-envelope.json"))
        guard case .failure(.rejected(let message)) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.contains("audio too long"), message)
    }

    /// An empty system stem (the 4 KB header-only file) transcribes to nothing.
    /// A 200 with no content is a failure, not an empty success — otherwise the
    /// meeting advances to "transcribed" with no transcript.
    func testEmptyResultIsAFailureEvenOnHTTP200() throws {
        let result = BoundaryResponses.readASR(status: 200, data: try fixture("asr-empty.json"))
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure, .empty)
    }

    func testOlderSidecarShapesStillParse() throws {
        let words = BoundaryResponses.readASR(status: 200, data: try fixture("asr-words-only.json"))
        guard case .success(let fromWords) = words else { return XCTFail("\(words)") }
        XCTAssertEqual(fromWords.rawText, "раз два три")
        XCTAssertEqual(fromWords.segments.first?.start, 0.5)
        XCTAssertEqual(fromWords.segments.first?.end, 3.4)

        let text = BoundaryResponses.readASR(status: 200, data: try fixture("asr-text-only.json"))
        guard case .success(let fromText) = text else { return XCTFail("\(text)") }
        XCTAssertEqual(fromText.rawText, "Просто строка без таймингов.")
        XCTAssertEqual(fromText.segments.first?.end, 9.0)
    }

    func testGarbageBodyOnA200IsMalformedNotACrash() {
        let result = BoundaryResponses.readASR(status: 200, data: Data("not json at all".utf8))
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure, .malformed)
    }

    // MARK: - Summary model

    func testReadsAnOrdinaryReply() throws {
        let result = BoundaryResponses.readChatReply(data: try fixture("chat-ok.json"))
        guard case .success(let content) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(content.hasPrefix("## Итог"))
    }

    /// The incident: qwen3.5 spent the entire context window in its `thinking`
    /// channel — 484 s, 12794 tokens, empty `content`. Retrying with the same
    /// settings burns the same minutes, so this must not look like a generic
    /// empty answer.
    func testReasoningModelThatAnswersNothingIsItsOwnFailure() throws {
        let result = BoundaryResponses.readChatReply(data: try fixture("chat-thinking-only.json"))
        guard case .failure(.reasonedItselfEmpty(let characters)) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertGreaterThan(characters, 0, "the thinking length is what tells them apart")
    }

    func testBlankReplyWithoutThinkingIsPlainEmpty() throws {
        let result = BoundaryResponses.readChatReply(data: try fixture("chat-empty.json"))
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure, .empty)
    }

    /// A proxy handed back an HTML error page. Decoding must fail cleanly
    /// rather than throw somewhere up the stack.
    func testHTMLErrorPageIsMalformed() throws {
        let result = BoundaryResponses.readChatReply(data: try fixture("chat-malformed.json"))
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure, .malformed)
    }

    func testEveryFixtureIsReadable() throws {
        // Guards against a fixture being renamed or lost — the tests above would
        // otherwise fail with a confusing decode error instead of a missing file.
        for name in [
            "asr-ok.json", "asr-words-only.json", "asr-text-only.json", "asr-413.txt",
            "asr-error-envelope.json", "asr-empty.json",
            "chat-ok.json", "chat-thinking-only.json", "chat-empty.json", "chat-malformed.json",
        ] {
            XCTAssertFalse(try fixture(name).isEmpty, name)
        }
    }
}
