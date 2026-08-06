import Foundation

/// Soft typewriter over a character range — the math only.
///
/// `progress` 0 → nothing visible, 1 → everything visible. The head advances in
/// reading order; a short soft edge fades glyphs in (or out when progress
/// retreats). Disappear is the same curve run backwards.
public enum SummaryTypewriter: Sendable {

    /// Alpha for character `index` (0..<count) at `progress` in 0...1.
    ///
    /// `softness` is the fade width in characters. Below 1 the edge is hard.
    /// The head travels `count + softness` so that at `progress == 1` the soft
    /// edge has cleared the last glyph (otherwise the tail stays half-lit).
    public static func alpha(
        at index: Int,
        count: Int,
        progress: Double,
        softness: Double
    ) -> Double {
        guard count > 0, index >= 0, index < count else { return 0 }
        let soft = max(softness, 0.0001)
        let head = min(max(progress, 0), 1) * (Double(count) + soft)
        // 1 well behind the head, 0 at the head, negative ahead of it.
        let t = (head - Double(index)) / soft
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        // Smoothstep — softer than a linear ramp across the glyph.
        return t * t * (3 - 2 * t)
    }

    /// How long an appear or dismiss should run for `count` characters.
    public static func duration(
        count: Int,
        secondsPerChar: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard count > 0 else { return minimum }
        return min(maximum, max(minimum, Double(count) * secondsPerChar))
    }
}
