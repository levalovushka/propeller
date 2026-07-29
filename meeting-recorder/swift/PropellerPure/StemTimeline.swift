import Foundation

/// Where each stem sits on one timeline.
///
/// # Why this exists
///
/// The two captures do not start together. The microphone writer is already
/// running when ScreenCaptureKit delivers its first buffer, and the gap is not
/// the 150 ms `Task.sleep` that precedes the stream: measured on a real meeting
/// it was **484 ms**, stable to ±3 ms across 43 minutes. Summing both stems from
/// index zero therefore puts the far end into the recording twice, half a second
/// apart — and half of their words stop reaching ASR. The numbers are in
/// `docs/ECHO_AND_MIX_EXPERIMENTS.md`: 52.9 % of the far end's words survive the
/// mix as it was, 95.0 % survive once the stems are aligned.
///
/// # Why the offset is measured during capture, not afterwards
///
/// The obvious alternative is to cross-correlate the two files at the end. It
/// works only when the microphone actually hears the far end — that is, only
/// when the user is on speakers. With headphones there is nothing to correlate
/// against, while the offset is exactly as real and exactly as wrong to ignore.
///
/// The second reason is live transcription. Interleaving two streams as they
/// arrive needs this number *during* the meeting; anything derived from the
/// finished files cannot be part of that path. So the offset is what the
/// microphone's own clock says when the system stem opens: how much microphone
/// audio was already on disk at that moment.
public enum StemTimeline {

    /// First sample of the system stem, expressed in microphone frames.
    @inlinable
    public static func systemStartFrame(offsetSeconds: Double, sampleRate: Double) -> Int {
        guard offsetSeconds.isFinite, offsetSeconds > 0, sampleRate > 0 else { return 0 }
        return Int((offsetSeconds * sampleRate).rounded())
    }

    /// Length of the mix that holds both stems whole.
    ///
    /// The system stem can outlast the microphone one — the mic writer is
    /// stopped first — so the answer is not simply the microphone's length.
    @inlinable
    public static func mixedFrameCount(
        micFrames: Int,
        systemFrames: Int,
        systemStartFrame: Int
    ) -> Int {
        max(max(0, micFrames), max(0, systemStartFrame) + max(0, systemFrames))
    }
}
