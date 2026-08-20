import Foundation

/// The bucket boundaries every funnel chart is drawn from.
///
/// They live here because a wrong boundary is invisible: the chart still draws,
/// the numbers still add up, and nobody can tell that «1-15m» has been counting
/// something else since a refactor. A telemetry rule that cannot be checked is a
/// telemetry rule that will be believed.
public enum TelemetryBuckets {

    /// How long a meeting ran.
    public static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "<1m"
        case ..<900: return "1-15m"
        case ..<3600: return "15-60m"
        default: return "60m+"
        }
    }

    /// How long a recording had been running when it was cancelled. The bottom
    /// bucket is the one that matters: an auto-started recording killed inside
    /// ten seconds is a wrong call detection, not a change of mind.
    public static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: return "<10s"
        case ..<60: return "10-60s"
        case ..<300: return "1-5m"
        default: return "5m+"
        }
    }
}
