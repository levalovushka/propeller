import Foundation
import AVFoundation
import FluidAudio
import PropellerMetrics
import Darwin

// Batch harness body (plan-testing-metrics M2). Entry point: BenchMain.swift.

func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--live") {
        try await runLive(args)
        return
    }
    let runs = max(1, intFlag(args, "-k") ?? 1)
    let skipASR = args.contains("--diarize-only")
    let fixtureDir = resolveFixtureDir(args)
    let audioURL = fixtureDir.appendingPathComponent("final.wav")
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
        throw BenchError.missingFixture(audioURL.path)
    }

    let audioDuration = try wavDuration(audioURL)
    print("Fixture: \(audioURL.path)")
    print("Duration: \(String(format: "%.2f", audioDuration))s  runs=\(runs)")

    var spawnSamples: [Double] = []
    var asrSamples: [Double] = []
    var asrCoreSamples: [Double] = []
    var diarizeSamples: [Double] = []
    var peakRSS: [Double] = []
    var afterReleaseRSS: [Double] = []

    if !skipASR {
        let spawnMs = try await ensureGigastt()
        spawnSamples.append(spawnMs)
        print(String(format: "sidecar.spawn: %.0f ms", spawnMs))
    }

    for i in 1...runs {
        print("--- run \(i)/\(runs) ---")
        var peak: UInt64 = currentRSSBytes()

        if !skipASR {
            // How many cores the offline pass actually occupies, not just how
            // long it takes. RTF says the wall-clock is short; it says nothing
            // about whether the machine is unusable while it lasts, and that is
            // the part a person feels right after a meeting ends.
            let sidecarPID = BenchMain.retainedGigastt?.processIdentifier
                ?? BenchMain.backgroundGigastt
            let costBefore = sidecarPID.flatMap { ProcessCost.of(pid: $0) }
            let t0 = Date()
            let (_, text) = try await PipelineMetrics.interval(
                PipelineMetrics.pipeline, PipelineMetrics.asr
            ) {
                try await GigasttHTTP.transcribe(audioURL: audioURL)
            }
            let asrS = Date().timeIntervalSince(t0)
            asrSamples.append(asrS)
            peak = max(peak, currentRSSBytes())
            print(String(format: "  asr: %.2fs (RTF %.3f) segs/text≈%d chars",
                         asrS, asrS / audioDuration, text.count))
            if let sidecarPID, let costBefore,
               let spent = ProcessCost.of(pid: sidecarPID)?.since(costBefore) {
                let cores = spent.cpuSeconds / asrS
                asrCoreSamples.append(cores)
                print(String(format: "  asr cpu: %.1f s over %.1f s wall — %.1f cores of %d",
                             spent.cpuSeconds, asrS, cores, ProcessInfo.processInfo.activeProcessorCount))
            }
        }

        let config = OfflineDiarizerConfig()
        var diarizer: OfflineDiarizerManager? = OfflineDiarizerManager(config: config)
        try await diarizer!.prepareModels()
        peak = max(peak, currentRSSBytes())

        let t1 = Date()
        let result = try await PipelineMetrics.interval(
            PipelineMetrics.pipeline, PipelineMetrics.diarize
        ) {
            try await diarizer!.process(audioURL)
        }
        let diaS = Date().timeIntervalSince(t1)
        diarizeSamples.append(diaS)
        peak = max(peak, currentRSSBytes())
        let speakers = Set(result.segments.map(\.speakerId)).count
        print(String(format: "  diarize: %.2fs (RTF %.3f) segments=%d speakers=%d",
                     diaS, diaS / audioDuration, result.segments.count, speakers))

        PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.release) {
            diarizer = nil
        }
        // Give the allocator a beat before sampling post-release RSS.
        try await Task.sleep(nanoseconds: 300_000_000)
        let released = currentRSSBytes()
        peakRSS.append(Double(peak) / 1_048_576)
        afterReleaseRSS.append(Double(released) / 1_048_576)
        print(String(format: "  peak_rss: %.1f MB  after_release: %.1f MB",
                     Double(peak) / 1_048_576, Double(released) / 1_048_576))
    }

    // Only the batch keys are touched: a `--live` run's numbers stay where they
    // are, so the two harnesses can be run separately and still diff together.
    // The fixture's own name, not a constant: a batch run on another clip used to
    // overwrite ru-short-2spk's numbers with numbers taken on different audio.
    let latestURL = try writeMetrics(
        fixture: fixtureDir.lastPathComponent, audioDuration: audioDuration, runs: runs
    ) { metrics in
        if !skipASR {
            metrics.asr_rtf = sampleStat(asrSamples.map { $0 / audioDuration }, tolerance: "+15%")
        }
        metrics.diarize_rtf = sampleStat(diarizeSamples.map { $0 / audioDuration }, tolerance: "+15%")
        if !spawnSamples.isEmpty {
            metrics.sidecar_spawn_ms = sampleStat(spawnSamples, tolerance: "+20%")
        }
        if !asrCoreSamples.isEmpty {
            metrics.asr_cpu_cores = sampleStat(asrCoreSamples, tolerance: "+15%", direction: .lower)
        }
        metrics.batch_peak_rss_mb = sampleStat(peakRSS, tolerance: "+10%")
        metrics.batch_rss_after_release_mb = sampleStat(afterReleaseRSS, tolerance: "+15%")
    }
    print("Wrote \(latestURL.path)")
}

/// One file per fixture, because a number is only comparable to a number taken
/// on the same audio. The original fixture keeps the unsuffixed names so the
/// existing baseline and every command in the docs still resolve.
func metricsFilename(_ kind: String, fixture: String) -> String {
    fixture == "ru-short-2spk" ? "\(kind).json" : "\(kind)-\(fixture).json"
}

/// Update `benchmarks/latest.json` in place, editing only the keys the caller
/// sets. Rewriting the file wholesale would erase the other harness's metrics,
/// and `bench-diff` reports a missing key as `skip` — a silently unguarded
/// metric, which is the failure mode this whole exercise exists to avoid.
func writeMetrics(
    fixture: String,
    audioDuration: Double,
    runs: Int,
    _ edit: (inout MetricsReport.Metrics) -> Void
) throws -> URL {
    let outDir = resolveBenchmarksDir()
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let latestURL = outDir.appendingPathComponent(metricsFilename("latest", fixture: fixture))

    var metrics = MetricsReport.Metrics()
    if let data = try? Data(contentsOf: latestURL),
       let previous = try? JSONDecoder().decode(MetricsReport.self, from: data) {
        metrics = previous.metrics
    }
    edit(&metrics)

    let report = MetricsReport(
        machine: Host.current().localizedName ?? "unknown",
        os: ProcessInfo.processInfo.operatingSystemVersionString,
        commit: gitCommit() ?? "unknown",
        fixture: fixture,
        audio_duration_s: audioDuration,
        runs: runs,
        metrics: metrics
    )
    try JSONEncoder.pretty.encode(report).write(to: latestURL, options: .atomic)
    return latestURL
}

// MARK: - gigastt

@discardableResult
func ensureGigastt() async throws -> Double {
    if let health = try? await GigasttHTTP.health(), health.model != "loading" {
        print("gigastt already healthy (model=\(health.model ?? "?"))")
        return 0
    }
    let binary = try resolveGigasttBinary()
    let modelDir = resolveGigasttModelDir()
    print("Spawning \(binary.path)")
    print("Models: \(modelDir.path)")

    let t0 = Date()
    let logURL = modelDir.deletingLastPathComponent().appendingPathComponent("bench-gigastt-serve.log")
    let serveArgs = [
        "serve", "--model-dir", modelDir.path, "--model-variant", "e2e_rnnt",
        "--port", "9876", "--pool-size", "1", "--hotwords-default",
    ]
    // Same server, same flags — only the QoS class differs, so the diff is the
    // scheduling policy and nothing else.
    if CommandLine.arguments.contains("--bg-asr") {
        guard let pid = spawnBackground(binary, serveArgs, log: logURL) else {
            throw BenchError.sidecarTimeout
        }
        BenchMain.backgroundGigastt = pid
        print("spawned under QOS_CLASS_BACKGROUND, pid \(pid)")
        for _ in 0..<180 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let h = try? await GigasttHTTP.health(), h.model != "loading" { break }
        }
        return Date().timeIntervalSince(t0) * 1000
    }
    try await PipelineMetrics.interval(PipelineMetrics.sidecar, PipelineMetrics.spawn) {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "serve",
            "--model-dir", modelDir.path,
            "--model-variant", "e2e_rnnt",
            "--port", "9876",
            "--pool-size", "1",
            "--hotwords-default",
        ]
        let logURL = modelDir.deletingLastPathComponent().appendingPathComponent("bench-gigastt-serve.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: logURL)
        proc.standardOutput = fh
        proc.standardError = fh
        try proc.run()
        BenchMain.retainedGigastt = proc
        for _ in 0..<180 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let h = try? await GigasttHTTP.health(), h.model != "loading" {
                return
            }
        }
        throw BenchError.sidecarTimeout
    }
    return Date().timeIntervalSince(t0) * 1000
}

func resolveGigasttBinary() throws -> URL {
    if let env = ProcessInfo.processInfo.environment["GIGASTT_BIN"] {
        let u = URL(fileURLWithPath: env)
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    let candidates = [
        URL(fileURLWithPath: "/Applications/Propeller.app/Contents/MacOS/gigastt"),
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/Propeller/tools/gigastt/gigastt"),
    ]
    for u in candidates where FileManager.default.isExecutableFile(atPath: u.path) {
        return u
    }
    throw BenchError.binaryNotFound
}

func resolveGigasttModelDir() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Meeting Recorder/gigastt-models", isDirectory: true)
    if gigasttModelsPresent(appSupport) { return appSupport }
    let dev = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Desktop/Propeller/tools/gigastt/models-e2e", isDirectory: true)
    if gigasttModelsPresent(dev) { return dev }
    return appSupport
}

func gigasttModelsPresent(_ dir: URL) -> Bool {
    let fm = FileManager.default
    return ["v3_e2e_rnnt_encoder_int8.onnx", "v3_e2e_rnnt_decoder.onnx", "v3_e2e_rnnt_joint.onnx"]
        .allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
}

// MARK: - Paths / utils

func resolveFixtureDir(_ args: [String]) -> URL {
    if let i = args.firstIndex(of: "--fixture"), args.index(after: i) < args.endIndex {
        return URL(fileURLWithPath: args[args.index(after: i)], isDirectory: true)
    }
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent() // Bench/
    let bundled = here.deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/ru-short-2spk", isDirectory: true)
    if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("final.wav").path) {
        return bundled
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Fixtures/ru-short-2spk", isDirectory: true)
}

func resolveBenchmarksDir() -> URL {
    if let env = ProcessInfo.processInfo.environment["PROPELLER_BENCHMARKS"] {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return here.deletingLastPathComponent().appendingPathComponent("benchmarks", isDirectory: true)
}

func wavDuration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

func intFlag(_ args: [String], _ name: String) -> Int? {
    guard let i = args.firstIndex(of: name), args.index(after: i) < args.endIndex else { return nil }
    return Int(args[args.index(after: i)])
}

func gitCommit() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    proc.currentDirectoryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func currentRSSBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

func sampleStat(
    _ values: [Double],
    tolerance: String,
    direction: MetricSample.Direction? = nil
) -> MetricSample {
    let sorted = values.sorted()
    let median = percentile(sorted, 0.50)
    let p90 = percentile(sorted, 0.90)
    return MetricSample(
        median: median, p90: p90, tolerance: tolerance, samples: values, direction: direction
    )
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    if sorted.count == 1 { return sorted[0] }
    let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[idx]
}

enum BenchError: LocalizedError {
    case missingFixture(String)
    case binaryNotFound
    case sidecarTimeout
    case portBusy(Int)
    case sessionFailed(String)
    case costUnavailable
    var errorDescription: String? {
        switch self {
        case .missingFixture(let p): return "Fixture not found: \(p)"
        case .binaryNotFound: return "gigastt binary not found (set GIGASTT_BIN)"
        case .sidecarTimeout: return "gigastt did not become healthy within 180s"
        case .portBusy(let port):
            return """
                Port \(port) already serves a healthy gigastt. The live harness \
                needs its own process to meter (pass --port N for another one), \
                and a server shared with the running app would mix its work into \
                the measurement.
                """
        case .sessionFailed(let why):
            return "live session failed — \(why); the run is not a measurement"
        case .costUnavailable:
            return "proc_pid_rusage refused: cannot meter CPU for this process"
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
