import Foundation

/// Shape of `benchmarks/latest.json` / `baseline.json` (plan-testing-metrics M3).
struct MetricSample: Codable {
    var median: Double
    var p90: Double
    var tolerance: String
    var samples: [Double]?
    /// Which way is better. Absent means `lower` — every metric predating the
    /// live harness is a cost, and old baselines must keep comparing as before.
    ///
    /// This field exists because quality metrics run the other way, and without
    /// it `bench-diff` reads a collapse in `live.coverage` — half the meeting
    /// gone — as an improvement, and green-lights the change that caused it.
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

        // The live layer (LiveHarness). Cost first, then what the cost buys —
        // and the two are only meaningful together: every metric below the line
        // is a guardrail on every metric above it.
        var live_sidecar_cpu_cores: MetricSample?
        var live_sidecar_gcycles_per_audio_s: MetricSample?
        var live_sidecar_peak_rss_mb: MetricSample?
        var live_app_cpu_cores: MetricSample?
        var live_frames_fed_ratio: MetricSample?
        var live_wer: MetricSample?
        var live_coverage: MetricSample?
        var live_attribution_accuracy: MetricSample?
        var live_lag_median_s: MetricSample?

        enum CodingKeys: String, CodingKey {
            case asr_rtf = "asr.rtf"
            case asr_cpu_cores = "asr.cpu_cores"
            case diarize_rtf = "diarize.rtf"
            case sidecar_spawn_ms = "sidecar.spawn_ms"
            case batch_peak_rss_mb = "batch.peak_rss_mb"
            case batch_rss_after_release_mb = "batch.rss_after_release_mb"
            case live_sidecar_cpu_cores = "live.sidecar_cpu_cores"
            case live_sidecar_gcycles_per_audio_s = "live.sidecar_gcycles_per_audio_s"
            case live_sidecar_peak_rss_mb = "live.sidecar_peak_rss_mb"
            case live_app_cpu_cores = "live.app_cpu_cores"
            case live_frames_fed_ratio = "live.frames_fed_ratio"
            case live_wer = "live.wer"
            case live_coverage = "live.coverage"
            case live_attribution_accuracy = "live.attribution_accuracy"
            case live_lag_median_s = "live.lag_median_s"
        }
    }
}
