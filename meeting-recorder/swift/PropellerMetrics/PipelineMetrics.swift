import Foundation
import OSLog

/// Shared OSSignposter intervals for the batch pipeline (plan-testing-metrics F1).
///
/// Subsystem `app.propeller`. Categories:
/// - `pipeline` — asr / diarize / mix / markdown / recap / release
/// - `sidecar`  — sidecar.spawn
///
/// Near-zero cost when nobody is listening; readable live in Instruments,
/// via `XCTOSSignpostMetric`, and from `log show --signpost` in the batch harness.
public enum PipelineMetrics {
    public static let subsystem = "app.propeller"

    public static let pipeline = OSSignposter(subsystem: subsystem, category: "pipeline")
    public static let sidecar = OSSignposter(subsystem: subsystem, category: "sidecar")

    // Interval names — keep stable; baseline / bench-diff keys derive from these.
    public static let spawn: StaticString = "sidecar.spawn"
    public static let asr: StaticString = "asr"
    public static let diarize: StaticString = "diarize"
    public static let mix: StaticString = "mix"
    public static let markdown: StaticString = "markdown"
    public static let recap: StaticString = "recap"
    public static let release: StaticString = "release"

    /// Measure an async throwing body under a signpost interval.
    @discardableResult
    public static func interval<T>(
        _ signposter: OSSignposter,
        _ name: StaticString,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    /// Measure a sync throwing body under a signpost interval.
    @discardableResult
    public static func interval<T>(
        _ signposter: OSSignposter,
        _ name: StaticString,
        _ body: () throws -> T
    ) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Measure an async non-throwing body.
    @discardableResult
    public static func interval<T>(
        _ signposter: OSSignposter,
        _ name: StaticString,
        _ body: () async -> T
    ) async -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return await body()
    }

    /// Measure a sync non-throwing body.
    @discardableResult
    public static func interval<T>(
        _ signposter: OSSignposter,
        _ name: StaticString,
        _ body: () -> T
    ) -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return body()
    }
}
