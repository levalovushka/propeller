import Foundation

/// How the two stems become one file, in blocks instead of all at once.
///
/// The mix used to read both stems whole: three buffers of `file.length` frames,
/// which is 195 MB per stem for a fifty-minute meeting and a ~584 MB peak — paid
/// on every meeting, and again in a loop at launch for every recording missing
/// its final mix (defect M1). Blocks make that constant.
///
/// The arithmetic lives here rather than beside the file handles because it is
/// the only part that can be wrong in a way nothing would notice: the mix is
/// unreachable from the test target (`Sources/` is an executable target), and no
/// consumer in the app compares its samples to anything. A block boundary
/// off by one would shift the far side of a conversation by a few frames and no
/// test, benchmark or screen would say a word.
public enum MixPlan {

    /// One write's worth of the output file.
    ///
    /// `micRange` and `systemRange` are frames to read from each stem; `nil`
    /// means that stem contributes silence to this block. The microphone always
    /// starts at output frame zero — that alignment is what makes transcript
    /// time and stem time the same clock — so its samples always land at the
    /// start of the block. The system stem can start anywhere, hence
    /// `systemOffsetInBlock`.
    public struct Block: Equatable, Sendable {
        public let outputStart: Int
        public let frameCount: Int
        public let micRange: Range<Int>?
        public let systemRange: Range<Int>?
        public let systemOffsetInBlock: Int

        public init(
            outputStart: Int,
            frameCount: Int,
            micRange: Range<Int>?,
            systemRange: Range<Int>?,
            systemOffsetInBlock: Int
        ) {
            self.outputStart = outputStart
            self.frameCount = frameCount
            self.micRange = micRange
            self.systemRange = systemRange
            self.systemOffsetInBlock = systemOffsetInBlock
        }
    }

    /// Every block of the mix, in order, covering exactly
    /// `StemTimeline.mixedFrameCount` frames and no more.
    ///
    /// The total is not negotiable: `recoverMissingFinalMixes` reads the finished
    /// file's duration back and writes it into the recording, where it becomes
    /// what the list, the archive and the assistant all report. A rewrite that
    /// rounds up to a block boundary would lengthen meetings.
    public static func blocks(
        micFrames: Int,
        systemFrames: Int,
        systemStartFrame: Int,
        blockSize: Int
    ) -> [Block] {
        let mic = max(0, micFrames)
        let sys = max(0, systemFrames)
        let start = max(0, systemStartFrame)
        let size = max(1, blockSize)
        let total = StemTimeline.mixedFrameCount(
            micFrames: mic, systemFrames: sys, systemStartFrame: start
        )
        guard total > 0 else { return [] }

        var blocks: [Block] = []
        blocks.reserveCapacity((total + size - 1) / size)
        var outputStart = 0
        while outputStart < total {
            let count = min(size, total - outputStart)
            let blockEnd = outputStart + count

            let micEnd = min(blockEnd, mic)
            let micRange: Range<Int>? = micEnd > outputStart ? outputStart..<micEnd : nil

            let sysFirst = max(outputStart, start)
            let sysLast = min(blockEnd, start + sys)
            let systemRange: Range<Int>? = sysLast > sysFirst
                ? (sysFirst - start)..<(sysLast - start)
                : nil

            blocks.append(
                Block(
                    outputStart: outputStart,
                    frameCount: count,
                    micRange: micRange,
                    systemRange: systemRange,
                    systemOffsetInBlock: systemRange == nil ? 0 : sysFirst - outputStart
                )
            )
            outputStart = blockEnd
        }
        return blocks
    }

    /// One block, summed and clamped.
    ///
    /// `mic` holds exactly the frames of `block.micRange`, `system` exactly those
    /// of `block.systemRange`. The clamp is hard at ±1 — measured 2026-08-20 as
    /// costing 7 samples in 869 000 on the fixture where it fires at all, and the
    /// argument for leaving it that way is written where the mix calls this.
    public static func sum(
        _ block: Block,
        mic: [Float],
        system: [Float],
        systemGain: Float
    ) -> [Float] {
        var out = [Float](repeating: 0, count: block.frameCount)
        if let micRange = block.micRange {
            let n = min(micRange.count, mic.count)
            for i in 0..<n { out[i] = mic[i] }
        }
        if let systemRange = block.systemRange {
            let n = min(systemRange.count, system.count)
            let base = block.systemOffsetInBlock
            for i in 0..<n where base + i < out.count {
                out[base + i] += system[i] * systemGain
            }
        }
        for i in 0..<out.count {
            if out[i] > 1 { out[i] = 1 } else if out[i] < -1 { out[i] = -1 }
        }
        return out
    }

    /// RMS and peak of a whole stem, gathered a block at a time.
    ///
    /// `MixGain` needs both over the entire file before a single frame can be
    /// summed, which is why the mix reads each stem twice. Computing gain per
    /// block instead would be a different algorithm — a loud passage would be
    /// pushed down and a quiet one lifted, inside one meeting — not a refactor.
    public struct Level {
        private var sumSquares: Double = 0
        private var maxAbs: Float = 0
        private var count: Int = 0

        public init() {}

        public mutating func add(_ samples: [Float]) {
            for value in samples {
                sumSquares += Double(value) * Double(value)
                let magnitude = value < 0 ? -value : value
                if magnitude > maxAbs { maxAbs = magnitude }
            }
            count += samples.count
        }

        /// Zero frames is zero level, matching the whole-buffer version this
        /// replaces — a stem that is missing must not look loud.
        public var rms: Float {
            count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0
        }

        public var peak: Float { count > 0 ? maxAbs : 0 }
    }
}
