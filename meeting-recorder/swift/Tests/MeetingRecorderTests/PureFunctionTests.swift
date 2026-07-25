import XCTest
import PropellerPure

final class PureFunctionTests: XCTestCase {

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
        XCTAssertEqual(RecordingRecovery.recoveredStatus(current: "recording", hasTranscript: false), "recorded")
        XCTAssertEqual(RecordingRecovery.recoveredStatus(current: "transcribing", hasTranscript: true), "transcribed_raw")
        XCTAssertEqual(RecordingRecovery.recoveredStatus(current: "transcribing", hasTranscript: false), "recorded")
        XCTAssertNil(RecordingRecovery.recoveredStatus(current: "saved", hasTranscript: true))
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
