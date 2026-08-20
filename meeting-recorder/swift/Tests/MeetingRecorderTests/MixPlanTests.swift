import XCTest
@testable import PropellerPure

/// The mix, block by block, against the whole-buffer sum it replaces.
///
/// This file is the only thing standing between a block-boundary mistake and a
/// silently wrong recording. `AudioRecorder` is in an executable target that no
/// test can import, and nothing in the app compares mix samples to a reference —
/// so an off-by-one at a block edge would ship green. The reference below is the
/// loop that was there before, transcribed line for line, and every case asserts
/// the streamed answer equals it sample for sample.
final class MixPlanTests: XCTestCase {

    // MARK: - The loop this replaces

    /// `AudioRecorder.mix`'s summation as it stood on 2026-08-20, whole buffers
    /// and all. Kept verbatim so "the same as before" is a claim a machine
    /// checks rather than a claim in a commit message.
    private func reference(
        mic: [Float], system: [Float], systemStart: Int, gain: Float
    ) -> [Float] {
        let n = StemTimeline.mixedFrameCount(
            micFrames: mic.count, systemFrames: system.count, systemStartFrame: systemStart
        )
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let m = i < mic.count ? mic[i] : 0
            let j = i - systemStart
            let s = (j >= 0 && j < system.count) ? system[j] * gain : 0
            var v = m + s
            if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
            out[i] = v
        }
        return out
    }

    private func streamed(
        mic: [Float], system: [Float], systemStart: Int, gain: Float, blockSize: Int
    ) -> [Float] {
        var out: [Float] = []
        for block in MixPlan.blocks(
            micFrames: mic.count,
            systemFrames: system.count,
            systemStartFrame: systemStart,
            blockSize: blockSize
        ) {
            let micSlice = block.micRange.map { Array(mic[$0]) } ?? []
            let sysSlice = block.systemRange.map { Array(system[$0]) } ?? []
            out += MixPlan.sum(block, mic: micSlice, system: sysSlice, systemGain: gain)
        }
        return out
    }

    private func ramp(_ count: Int, seed: Float) -> [Float] {
        (0..<count).map { i in
            let x = Float(i) * 0.017 + seed
            return sin(x) * 0.6 + sin(x * 3.1) * 0.3
        }
    }

    // MARK: - Streamed equals whole-buffer

    /// Every shape that has ever mattered here: the system stem outlasting the
    /// microphone, an offset that is not on a block boundary, one stem missing
    /// entirely — each against block sizes that do and do not divide the total.
    func testBlocksSumToExactlyWhatOneBigBufferDid() {
        let shapes: [(mic: Int, sys: Int, start: Int, gain: Float)] = [
            (1000, 1000, 0, 1.0),
            (1000, 1000, 0, 2.5),
            (1000, 900, 7744 % 300, 1.7),
            (1000, 990, 137, 1.0),
            (500, 900, 300, 1.0),      // system outlasts the microphone
            (900, 500, 700, 3.0),      // system starts late and ends early
            (1000, 0, 0, 1.0),         // mic only
            (0, 1000, 0, 1.0),         // system only
            (0, 0, 0, 1.0),            // nothing at all
            (1000, 1000, 1200, 1.0),   // system starts after the mic ended
            (7, 5, 3, 4.0),            // shorter than any block
        ]
        for shape in shapes {
            let mic = ramp(shape.mic, seed: 0.3)
            let sys = ramp(shape.sys, seed: 1.9)
            let want = reference(mic: mic, system: sys, systemStart: shape.start, gain: shape.gain)
            for blockSize in [1, 2, 3, 64, 128, 333, 1024, 1 << 16] {
                let got = streamed(
                    mic: mic, system: sys, systemStart: shape.start,
                    gain: shape.gain, blockSize: blockSize
                )
                XCTAssertEqual(
                    got, want,
                    "shape mic=\(shape.mic) sys=\(shape.sys) start=\(shape.start) block=\(blockSize)"
                )
            }
        }
    }

    /// A meeting's length is read back off this file and stored, so the block
    /// plan must cover the mix exactly — not up to the next block boundary.
    func testTheBlocksCoverTheMixAndNotOneFrameMore() {
        for (mic, sys, start) in [(1000, 1000, 0), (1000, 900, 137), (500, 900, 300), (0, 0, 0)] {
            let total = StemTimeline.mixedFrameCount(
                micFrames: mic, systemFrames: sys, systemStartFrame: start
            )
            for blockSize in [1, 7, 128, 4096] {
                let blocks = MixPlan.blocks(
                    micFrames: mic, systemFrames: sys, systemStartFrame: start, blockSize: blockSize
                )
                XCTAssertEqual(blocks.reduce(0) { $0 + $1.frameCount }, total)
                var expectedStart = 0
                for block in blocks {
                    XCTAssertEqual(block.outputStart, expectedStart)
                    XCTAssertLessThanOrEqual(block.frameCount, blockSize)
                    expectedStart += block.frameCount
                }
            }
        }
    }

    /// The microphone's frame zero is the mix's frame zero. Speaker attribution
    /// reads the stems inside windows taken from the transcript, and the
    /// transcript is timed against the mix — shift the origin and every «кто
    /// сказал» moves with it.
    func testTheMicrophoneStartsTheFile() {
        let blocks = MixPlan.blocks(
            micFrames: 1000, systemFrames: 900, systemStartFrame: 137, blockSize: 128
        )
        XCTAssertEqual(blocks.first?.micRange, 0..<128)
        // The system stem opens at 137, so it contributes nothing to block 0 —
        // silence, not an empty range that a reader might try to fetch.
        XCTAssertNil(blocks.first?.systemRange)
        XCTAssertEqual(blocks.first?.systemOffsetInBlock, 0)

        // The block the system stem actually opens in: 137 lands inside block 1.
        let second = blocks[1]
        XCTAssertEqual(second.systemOffsetInBlock, 137 - 128)
        XCTAssertEqual(second.systemRange, 0..<(256 - 137))
    }

    func testAZeroLengthMixHasNoBlocks() {
        XCTAssertTrue(
            MixPlan.blocks(micFrames: 0, systemFrames: 0, systemStartFrame: 0, blockSize: 64).isEmpty
        )
    }

    // MARK: - Levels gathered a block at a time

    /// `MixGain` reads RMS and peak over the whole stem, so streaming them has
    /// to give the same answer the whole-buffer pass gave — otherwise the gain
    /// changes and with it every sample of the mix.
    func testLevelsMatchTheWholeBufferPass() {
        let samples = ramp(5000, seed: 0.11)
        var whole = MixPlan.Level()
        whole.add(samples)

        for blockSize in [1, 3, 512, 5000, 9999] {
            var streamedLevel = MixPlan.Level()
            var i = 0
            while i < samples.count {
                let end = min(i + blockSize, samples.count)
                streamedLevel.add(Array(samples[i..<end]))
                i = end
            }
            XCTAssertEqual(streamedLevel.rms, whole.rms, accuracy: 1e-6, "block \(blockSize)")
            XCTAssertEqual(streamedLevel.peak, whole.peak, "block \(blockSize)")
        }
    }

    /// A stem that is not there must not read as loud: `MixGain` gives a silent
    /// system stem gain 1, and that is the branch keeping a quiet-but-real far
    /// side from being thrown away.
    func testNoFramesIsNoLevel() {
        let empty = MixPlan.Level()
        XCTAssertEqual(empty.rms, 0)
        XCTAssertEqual(empty.peak, 0)
    }

    // MARK: - On the real fixtures

    private func stem(_ fixture: String, _ name: String) throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixture)/\(name)")
        let data = try Data(contentsOf: url)
        // Canonical 44-byte PCM header, 16-bit mono — the format both stems and
        // the mix are pinned to.
        guard data.count > 44 else { return [] }
        let body = data.dropFirst(44)
        var out = [Float](repeating: 0, count: body.count / 2)
        body.withUnsafeBytes { raw in
            for i in 0..<out.count {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }
        return out
    }

    /// The same claim as the synthetic cases, made on the two committed
    /// recordings: nine hundred thousand real samples, sixteen block sizes,
    /// same answer as one big buffer.
    func testBothFixturesMixIdenticallyBlockByBlock() throws {
        for fixture in ["ru-short-2spk", "ru-pauses-2spk"] {
            let mic = try stem(fixture, "final.mic.wav")
            let sys = try stem(fixture, "final.sys.wav")
            XCTAssertGreaterThan(mic.count, 16_000, "\(fixture): mic stem looks empty")
            XCTAssertGreaterThan(sys.count, 16_000, "\(fixture): system stem looks empty")

            var micLevel = MixPlan.Level(); micLevel.add(mic)
            var sysLevel = MixPlan.Level(); sysLevel.add(sys)
            let gain = MixGain.systemMixGain(
                micRMS: micLevel.rms, micPeak: micLevel.peak,
                systemRMS: sysLevel.rms, systemPeak: sysLevel.peak
            )

            let want = reference(mic: mic, system: sys, systemStart: 0, gain: gain)
            for blockSize in [1024, 4096, 1 << 16, 7717] {
                let got = streamed(
                    mic: mic, system: sys, systemStart: 0, gain: gain, blockSize: blockSize
                )
                XCTAssertEqual(got.count, want.count, "\(fixture) block \(blockSize)")
                XCTAssertEqual(got, want, "\(fixture) block \(blockSize)")
            }

            // And with the legacy offset the recovery path can still hand us.
            let start = StemTimeline.systemStartFrame(offsetSeconds: 0.484, sampleRate: 16_000)
            let shifted = reference(mic: mic, system: sys, systemStart: start, gain: gain)
            XCTAssertEqual(
                streamed(mic: mic, system: sys, systemStart: start, gain: gain, blockSize: 4096),
                shifted,
                "\(fixture) with a 0.484 s offset"
            )
        }
    }
}
