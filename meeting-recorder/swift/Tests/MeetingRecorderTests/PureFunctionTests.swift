import XCTest
import Foundation
import PropellerPure

final class PureFunctionTests: XCTestCase {

    /// The exact reply that cost meeting 20260727_213023 its topics: the model
    /// wrote our own `1:1` tag without quotes, JSON parsing failed, and
    /// `generateMetadata` returned nil silently — leaving topics nil forever.
    func testParseMetadataRepairsUnquotedVocabularyTag() {
        let raw = #"{"title": "Тестовая встреча", "topics": ["проверка ИИ"], "tags": [1:1]}"#
        let meta = RecapMetadataParser.parse(raw, allowedTags: ["1:1", "ретро"])
        XCTAssertEqual(meta?.title, "Тестовая встреча")
        XCTAssertEqual(meta?.topics, ["проверка ИИ"])
        XCTAssertEqual(meta?.tags, ["1:1"])
    }

    func testRepairLeavesValidJSONAndRealScalarsAlone() {
        // Well-formed input must survive the repair byte-for-byte in meaning.
        let good = #"{"title": null, "topics": ["a, b", "c"], "tags": []}"#
        let meta = RecapMetadataParser.parse(good, allowedTags: [])
        XCTAssertNil(meta?.title)
        XCTAssertEqual(meta?.topics, ["a, b", "c"])   // comma inside a string is not a separator
        // Numbers and literals must stay real scalars, not become "12"/"true".
        // Compared as parsed JSON: the repair does not preserve whitespace, and
        // its output is only ever handed to JSONSerialization.
        let repaired = RecapMetadataParser.quotingBareArrayTokens(#"{"a": [12, true, null]}"#)
        let object = try? JSONSerialization.jsonObject(with: Data(repaired.utf8))
        let dict = object as? [String: Any]
        guard let arr = dict?["a"] as? [Any] else {
            return XCTFail("repair produced unparseable JSON: \(repaired)")
        }
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0] as? Int, 12)
        XCTAssertEqual(arr[1] as? Bool, true)
        XCTAssertTrue(arr[2] is NSNull)
    }

    // MARK: - OllamaRetry

    /// The failure that actually stranded a download on 2026-07-27: the link
    /// dropped mid-pull. This must retry, or a 3.4 GB download dies on a blip.
    func testDroppedConnectionIsRetryable() {
        let real = #"pull model manifest: Get "https://registry.ollama.ai/v2/library/qwen3.5/manifests/4b": dial tcp: lookup registry.ollama.ai: no such host"#
        XCTAssertTrue(OllamaRetry.isRetryable(message: real))
        for m in ["unexpected EOF", "connection reset by peer", "context deadline exceeded: timeout",
                  "TLS handshake timeout", "network is unreachable"] {
            XCTAssertTrue(OllamaRetry.isRetryable(message: m), m)
        }
    }

    /// These fail identically forever — retrying buys 17 minutes of silence and
    /// then the same error, so the user must hear about them immediately.
    func testPermanentFailuresAreNotRetried() {
        for m in ["pull model manifest: manifest unknown",
                  "write /models/blobs/sha256-abc: no space left on device",
                  "model \"qwen9:999b\" not found",
                  "unauthorized: authentication required"] {
            XCTAssertFalse(OllamaRetry.isRetryable(message: m), m)
        }
    }

    /// A permanent reason wrapped in transport wording must still read permanent —
    /// this is why the permanent list is checked first.
    func testPermanentWinsOverTransientWording() {
        XCTAssertFalse(OllamaRetry.isRetryable(
            message: "Get \"https://registry.ollama.ai/v2/...\": manifest unknown"))
        XCTAssertFalse(OllamaRetry.isRetryable(
            message: "connection established, then: no space left on device"))
    }

    func testUnknownFailureIsNotRetried() {
        XCTAssertFalse(OllamaRetry.isRetryable(message: "something completely unexpected"))
        XCTAssertFalse(OllamaRetry.isRetryable(message: ""))
    }

    // MARK: - BuiltinHotwords

    /// `vocab/hotwords-core.txt` is the human-maintained source; the Swift
    /// constant is a paste of it. This fails when someone edits one and not the
    /// other — the whole point of shipping a baseline is that it stays current.
    func testBuiltinHotwordsMatchVocabFile() throws {
        // …/meeting-recorder/swift/Tests/MeetingRecorderTests/PureFunctionTests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // → MeetingRecorderTests/
            .deletingLastPathComponent()   // → Tests/
            .deletingLastPathComponent()   // → swift/
            .deletingLastPathComponent()   // → meeting-recorder/
            .deletingLastPathComponent()   // → repo root
        let vocab = repoRoot.appendingPathComponent("vocab/hotwords-core.txt")
        guard let raw = try? String(contentsOf: vocab, encoding: .utf8) else {
            throw XCTSkip("vocab/hotwords-core.txt not present (shallow checkout)")
        }
        let fromFile = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(BuiltinHotwords.terms, fromFile,
                       "BuiltinHotwords.terms drifted from vocab/hotwords-core.txt")
    }

    func testMergedHotwordsAppendUserTermsAndDedupe() {
        let merged = BuiltinHotwords.merged(withUserTerms: ["Пропеллер", "  ", "Газпромнефть", "ДЕЙЛИК"])
        // User's own term lands after the baseline…
        XCTAssertTrue(merged.contains("Газпромнефть"))
        // …blanks are dropped, and a term we already ship isn't duplicated
        // just because the user typed it in a different case.
        XCTAssertFalse(merged.contains("  "))
        XCTAssertEqual(merged.filter { $0.lowercased() == "дейлик" }.count, 1)
        XCTAssertEqual(merged.filter { $0.lowercased() == "пропеллер" }.count, 1)
        // Baseline still leads the file.
        XCTAssertEqual(merged.first, BuiltinHotwords.terms.first)
    }

    // MARK: - OllamaContext

    /// The real regression: a 42-minute Russian meeting is ~14 285 characters
    /// (measured 2026-07-27 → 5538 tokens). It must land in a window that holds
    /// the whole thing, not the 4k default that showed the model only 2050.
    func testNumCtxHoldsARealFortyMinuteMeeting() {
        let systemPrompt = 3_200          // defaultPrompt + languageLock
        let ctx = OllamaContext.numCtx(promptCharacters: 14_285 + systemPrompt)
        XCTAssertEqual(ctx, 16_384)
        let needed = OllamaContext.estimatedTokens(promptCharacters: 14_285 + systemPrompt)
        XCTAssertLessThan(needed + OllamaContext.replyTokens, ctx)
    }

    /// The estimate must not *under*count tokens, or we size the window too small
    /// and silently truncate again. 2.2 chars/token vs ~2.6 measured.
    func testTokenEstimateIsConservative() {
        XCTAssertGreaterThan(OllamaContext.estimatedTokens(promptCharacters: 14_285), 5_538)
    }

    func testNumCtxEscalatesForLongMeetingsThenClamps() {
        // ~3 h of speech: past the 16k bucket, still inside the largest.
        let long = OllamaContext.numCtx(promptCharacters: 45_000)
        XCTAssertEqual(long, 32_768)
        // Absurd input clamps instead of asking for a window Ollama can't give.
        XCTAssertEqual(OllamaContext.numCtx(promptCharacters: 5_000_000), 32_768)
        XCTAssertTrue(OllamaContext.exceedsLargestWindow(promptCharacters: 5_000_000))
        XCTAssertFalse(OllamaContext.exceedsLargestWindow(promptCharacters: 14_285))
    }

    /// A short metadata prompt must reuse the same window as the recap that just
    /// ran — a different num_ctx makes Ollama reload the model from cold.
    func testShortMetadataPromptSharesTheRecapWindow() {
        XCTAssertEqual(OllamaContext.numCtx(promptCharacters: 1_500),
                       OllamaContext.numCtx(promptCharacters: 14_285 + 3_200))
        XCTAssertEqual(OllamaContext.numCtx(promptCharacters: 0), 16_384)
    }

    // MARK: - RecapMetadataParser

    func testParseMetadataValidJSON() {
        let raw = #"{"title": "Спринт планирование", "topics": ["бэклог", "риски"], "tags": ["планирование", "внутренняя"]}"#
        let meta = RecapMetadataParser.parse(raw, allowedTags: ["планирование", "внутренняя"])
        XCTAssertEqual(meta?.title, "Спринт планирование")
        XCTAssertEqual(meta?.topics, ["бэклог", "риски"])
        XCTAssertEqual(meta?.tags, ["планирование", "внутренняя"])
    }

    func testParseMetadataStripsFencesAndRejectsUnknownTags() {
        let fenced = RecapMetadataParser.stripCodeFences("""
        ```json
        {"title": null, "topics": ["a"], "tags": ["планирование", "not-a-real-tag"]}
        ```
        """)
        let meta = RecapMetadataParser.parse(fenced, allowedTags: ["планирование"])
        XCTAssertNil(meta?.title)
        XCTAssertEqual(meta?.topics, ["a"])
        XCTAssertEqual(meta?.tags, ["планирование"])
    }

    func testParseMetadataGarbageReturnsNil() {
        XCTAssertNil(RecapMetadataParser.parse("not json at all", allowedTags: []))
        XCTAssertNil(RecapMetadataParser.parse("", allowedTags: []))
    }

    // MARK: - DiarizationMerge

    func testSpeakerLabelMidpointHit() {
        let dia: [(id: String, start: Float, end: Float)] = [("0", 0, 10), ("1", 10, 20)]
        XCTAssertEqual(DiarizationMerge.speakerLabel(forMidpoint: 5, diarization: dia), "Speaker 0")
        XCTAssertEqual(DiarizationMerge.speakerLabel(forMidpoint: 15, diarization: dia), "Speaker 1")
    }

    func testSpeakerLabelClosestWhenGap() {
        let dia: [(id: String, start: Float, end: Float)] = [("0", 0, 5), ("1", 20, 25)]
        XCTAssertEqual(DiarizationMerge.speakerLabel(forMidpoint: 12, diarization: dia), "Speaker 0")
    }

    func testSpeakerLabelEmptyDiarization() {
        XCTAssertEqual(DiarizationMerge.speakerLabel(forMidpoint: 1, diarization: []), "Speaker")
    }

    // MARK: - SourceAwareSpeaker

    func testSourceAwareSystemNeverGetsOwnerName() {
        XCTAssertEqual(
            SourceAwareSpeaker.resolve(
                fluidDisplayName: "leva",
                source: .system,
                ownerName: "leva"
            ),
            "Speaker 1"
        )
    }

    func testSourceAwareMicGetsOwnerName() {
        XCTAssertEqual(
            SourceAwareSpeaker.resolve(
                fluidDisplayName: "Speaker 0",
                source: .microphone,
                ownerName: "leva"
            ),
            "leva"
        )
    }

    func testSourceAwareKeepsRemoteFluidLabel() {
        XCTAssertEqual(
            SourceAwareSpeaker.resolve(
                fluidDisplayName: "Speaker 2",
                source: .system,
                ownerName: "leva"
            ),
            "Speaker 2"
        )
    }

    func testSourceAwareMixedLeavesFluid() {
        XCTAssertEqual(
            SourceAwareSpeaker.resolve(
                fluidDisplayName: "leva",
                source: .mixed,
                ownerName: "leva"
            ),
            "leva"
        )
    }

    // MARK: - MixGain

    func testSystemMixGainSilentSystemReturnsOne() {
        XCTAssertEqual(
            MixGain.systemMixGain(micRMS: 0.05, micPeak: 0.2, systemRMS: 0, systemPeak: 0),
            1
        )
    }

    func testSystemMixGainClampedBetweenOneAndFour() {
        let gain = MixGain.systemMixGain(micRMS: 0.08, micPeak: 0.5, systemRMS: 0.005, systemPeak: 0.02)
        XCTAssertGreaterThanOrEqual(gain, 1)
        XCTAssertLessThanOrEqual(gain, 4)
    }

    // MARK: - WavHeader

    func testWavDurationParsesHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        var data = Data()
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8)
        appendU32(36 + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendU32(16)
        appendU16(1)
        appendU16(channels)
        appendU32(sampleRate)
        appendU32(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8))
        appendU16(channels * bitsPerSample / 8)
        appendU16(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        appendU32(dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)

        XCTAssertEqual(WavHeader.duration(url: url), 1.0, accuracy: 0.01)
    }

    // MARK: - RecordingRecovery

    func testRecoveredStatusTransitions() {
        XCTAssertEqual(RecordingRecovery.recoveredStage(current: .recording, hasTranscript: false), .recorded)
        XCTAssertEqual(RecordingRecovery.recoveredStage(current: .transcribing, hasTranscript: true), .transcribedRaw)
        XCTAssertEqual(RecordingRecovery.recoveredStage(current: .transcribing, hasTranscript: false), .recorded)
        XCTAssertNil(RecordingRecovery.recoveredStage(current: .saved, hasTranscript: true))
    }

    /// Invariant I4: a crash after the ASR checkpoint must never cost the pass.
    func testRecoveryNeverDropsBelowTheASRCheckpoint() {
        for stage in RecordingStage.allCases {
            let landed = RecordingRecovery.recoveredStage(current: stage, hasTranscript: true) ?? stage
            if stage >= .transcribedRaw {
                XCTAssertGreaterThanOrEqual(landed, .transcribedRaw, "\(stage)")
            }
        }
    }

    // MARK: - GigasttChunking

    func testNeedsChunkingBySizeAndDuration() {
        XCTAssertFalse(GigasttChunking.needsChunking(fileBytes: 1_000_000, durationSeconds: 60))
        XCTAssertTrue(GigasttChunking.needsChunking(fileBytes: GigasttChunking.maxSingleShotBytes + 1, durationSeconds: 60))
        XCTAssertTrue(GigasttChunking.needsChunking(fileBytes: 1_000_000, durationSeconds: GigasttChunking.maxSingleShotSeconds + 1))
        // 43‑min meeting class (~79 MiB) must chunk
        XCTAssertTrue(GigasttChunking.needsChunking(fileBytes: 79_000_000, durationSeconds: 43 * 60))
    }

    func testChunkMergeAppliesOffsets() {
        let a = [GigasttChunking.Segment(start: 1, end: 2, text: "one")]
        let b = [GigasttChunking.Segment(start: 0.5, end: 1.5, text: "two")]
        let merged = GigasttChunking.merge([
            (offset: 0, segments: a),
            (offset: 1200, segments: b),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].text, "one")
        XCTAssertEqual(merged[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(merged[1].text, "two")
        XCTAssertEqual(merged[1].start, 1200.5, accuracy: 0.001)
        XCTAssertEqual(merged[1].end, 1201.5, accuracy: 0.001)
    }
}
