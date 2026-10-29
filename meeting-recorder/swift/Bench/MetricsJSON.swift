import Foundation

/// Shape of `benchmarks/latest.json` / `baseline.json` (plan-testing-metrics M3).
struct MetricSample: Codable {
    var median: Double
    var p90: Double
    var tolerance: String
    var samples: [Double]?
    /// Which way is better. Absent means `lower` — a cost.
    ///
    /// This field exists because quality metrics run the other way, and without
    /// it `bench-diff` reads a collapse in coverage — half the meeting gone — as
    /// an improvement, and green-lights the change that caused it.
    var direction: Direction?

    enum Direction: String, Codable {
        case lower, higher
    }
}

struct MetricsReport: Codable {
    var machine: String
    var os: String
    var commit: String
    var fixture: String
    var audio_duration_s: Double
    var runs: Int
    var metrics: Metrics

    struct Metrics: Codable {
        var asr_rtf: MetricSample?
        /// Cores the offline ASR pass occupies while it runs. RTF says how long
        /// it takes; this says whether the machine is usable meanwhile — the part
        /// a person feels in the minutes right after a meeting ends.
        var asr_cpu_cores: MetricSample?
        var diarize_rtf: MetricSample?
        var sidecar_spawn_ms: MetricSample?
        var batch_peak_rss_mb: MetricSample?
        var batch_rss_after_release_mb: MetricSample?

        // The UI. Not the whole of it — only the part with a ruler so far: the
        // archive search that used to run, with disk reads, inside `body`.
        var ui_search_ms: MetricSample?
        var ui_search_render_ms: MetricSample?

        enum CodingKeys: String, CodingKey {
            case asr_rtf = "asr.rtf"
            case asr_cpu_cores = "asr.cpu_cores"
            case diarize_rtf = "diarize.rtf"
            case sidecar_spawn_ms = "sidecar.spawn_ms"
            case batch_peak_rss_mb = "batch.peak_rss_mb"
            case batch_rss_after_release_mb = "batch.rss_after_release_mb"
            case ui_search_ms = "ui.search_ms"
            case ui_search_render_ms = "ui.search_render_ms"
        }
    }
}
