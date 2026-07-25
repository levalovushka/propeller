import Foundation

/// Shape of `benchmarks/latest.json` / `baseline.json` (plan-testing-metrics M3).
struct MetricSample: Codable {
    var median: Double
    var p90: Double
    var tolerance: String
    var samples: [Double]?
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
        var diarize_rtf: MetricSample?
        var sidecar_spawn_ms: MetricSample?
        var batch_peak_rss_mb: MetricSample?
        var batch_rss_after_release_mb: MetricSample?

        enum CodingKeys: String, CodingKey {
            case asr_rtf = "asr.rtf"
            case diarize_rtf = "diarize.rtf"
            case sidecar_spawn_ms = "sidecar.spawn_ms"
            case batch_peak_rss_mb = "batch.peak_rss_mb"
            case batch_rss_after_release_mb = "batch.rss_after_release_mb"
        }
    }
}
