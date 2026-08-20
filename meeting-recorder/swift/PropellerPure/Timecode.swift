import Foundation

/// Where on the meeting's clock something happened — and the two shapes the app
/// says that in.
///
/// `text` is the one a person reads: `12:34`, and `1:02:03` once an hour is
/// past. `minutesSeconds` is the one the transcript file on disk has always
/// carried: minutes with no ceiling, so an hour and a half reads `90:12`.
///
/// They differ on purpose, and until 2026-08-20 they differed in six places at
/// once — five formatters and four parsers for one stamp, agreeing only because
/// the one that reaches disk never emits hours. Both live here now so the next
/// person changing one can see the other.
public enum Timecode {

    /// `12:34`, and `1:02:03` past an hour. What a person reads: a timer, a
    /// note's stamp, a remark's time in the transcript view.
    public static func text(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Minutes with no ceiling: `90:12` for an hour and a half. This is the
    /// stamp inside the saved transcript, and it is **not** `text` for a
    /// reason worth reading before changing it.
    ///
    /// Every transcript already on someone's disk carries this shape. Switching
    /// the writer to `text` would start emitting three components, which
    /// `transcriptHeadPattern` accepts — but a reader that does not would stop
    /// recognising the block head, keep the words, and drop the speaker and the
    /// time. That is the failure this type exists to make visible: change the
    /// writer only together with every parser, and only knowing that old files
    /// keep the old shape forever.
    public static func minutesSeconds(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Seconds back out of either shape — `MM:SS` or `H:MM:SS`, minutes
    /// uncapped. `nil` when the text is not a stamp at all; a caller that would
    /// rather have a number than a decision uses `?? 0`.
    public static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + Double(value)
        }
        return total
    }

    /// The head of a transcript block: `[Иван] [12:34]`, or `[Иван] [1:02:34]`.
    ///
    /// One definition, because two of them are how a format drifts: the writer
    /// and both readers were separately deciding whether a third component was
    /// allowed, and they did not agree.
    public static let transcriptHeadPattern = #"^\[(.+?)\]\s*\[(\d+:\d+(?::\d+)?)\]$"#
}
