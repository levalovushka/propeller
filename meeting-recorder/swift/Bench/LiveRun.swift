import Foundation
import PropellerPure

/// `swift run -c release Bench -- --live [-k N] [--port 9877] [--no-warmup]`
///
/// Streams the fixture's stems in real time and writes the `live.*` keys of
/// `benchmarks/latest.json`. One run takes as long as the audio — that is the
/// point of it, not an oversight.
func runLive(_ args: [String]) async throws {
    let runs = max(1, intFlag(args, "-k") ?? 1)
    let port = intFlag(args, "--port") ?? 9877
    let warmup = !args.contains("--no-warmup")
    let fixtureDir = resolveFixtureDir(args)
    // `--gate` measures the candidate; without it the harness measures what
    // ships. Both write the same keys, so a diff of the two files is the
    // hypothesis being answered. The rules are separable because they buy
    // different things at different prices — `--gate=silence`, `--gate=echo`,
    // or plain `--gate` for both.
    let gate: FeedGate?
    switch args.first(where: { $0.hasPrefix("--gate") }) {
    case "--gate=silence": gate = FeedGate(rules: .silence)
    case "--gate=echo": gate = FeedGate(rules: .echo)
    case "--gate", "--gate=both": gate = FeedGate(rules: .both)
    default: gate = nil
    }

    let gateLabel: String
    switch gate?.rules {
    case .none: gateLabel = ""
    case .some(.silence): gateLabel = ", gate: silence"
    case .some(.echo): gateLabel = ", gate: echo"
    default: gateLabel = ", gate: silence+echo"
    }
    print("Live harness — fixture \(fixtureDir.lastPathComponent), runs=\(runs), port=\(port)\(gateLabel)")
    if let appBusy = try? await LiveHealth.probe(port: 9876), appBusy {
        print("""
            NOTE: a gigastt is healthy on 9876 — probably the app's. It will not be \
            measured, but it does share the machine: close Propeller for a clean run.
            """)
    }

    var outcomes: [LiveHarness.Outcome] = []
    for i in 1...runs {
        print("--- run \(i)/\(runs) ---")
        let outcome = try await LiveHarness.run(
            fixtureDir: fixtureDir, port: port, warmup: warmup && i == 1, gate: gate
        )
        outcomes.append(outcome)
        report(outcome)
    }

    let audioSeconds = outcomes[0].audioSeconds
    let attribution = outcomes.compactMap(\.attributionAccuracy)

    let latestURL = try writeMetrics(
        fixture: fixtureDir.lastPathComponent, audioDuration: audioSeconds, runs: runs
    ) { metrics in
        // Cost: lower is better, and 10 % is the noise a shared laptop makes.
        metrics.live_sidecar_cpu_cores = sampleStat(
            outcomes.map(\.sidecarCPUCores), tolerance: "+10%", direction: .lower
        )
        metrics.live_sidecar_gcycles_per_audio_s = sampleStat(
            outcomes.map(\.sidecarGigacyclesPerAudioSecond), tolerance: "+10%", direction: .lower
        )
        // Wide on purpose. Identical runs of the same 27 s clip measured 546,
        // 943, 1116, 1133 and 1312 MB — the engine's allocator, not a leak (no
        // sidecar outlives a run; checked). A 10 % gate on a number that moves
        // 2x by itself only teaches people to ignore red. Kept because the
        // absolute figure matters — the comment at GigasttSidecar.swift:335
        // promises ~547 MB, and the ceiling is over a gigabyte.
        metrics.live_sidecar_peak_rss_mb = sampleStat(
            outcomes.map(\.sidecarPeakRSSMB), tolerance: "+50%", direction: .lower
        )
        metrics.live_app_cpu_cores = sampleStat(
            outcomes.map(\.appCPUCores), tolerance: "+20%", direction: .lower
        )
        // Not a cost and not a quality — the receipt. A change that claims a
        // saving has to show here how much audio it stopped sending.
        metrics.live_frames_fed_ratio = sampleStat(
            outcomes.map(\.framesFedRatio), tolerance: "+10%", direction: .lower
        )

        // Quality guardrails. Absolute tolerances, not percentages: 2 % of a WER
        // of 0.1 is 0.002, which no run reproduces, and a guardrail that trips on
        // noise gets deleted by the third person who sees it.
        metrics.live_wer = sampleStat(
            outcomes.map(\.wer), tolerance: "+0.03", direction: .lower
        )
        metrics.live_coverage = sampleStat(
            outcomes.map(\.coverage), tolerance: "0.02", direction: .higher
        )
        if !attribution.isEmpty {
            metrics.live_attribution_accuracy = sampleStat(
                attribution, tolerance: "0.05", direction: .higher
            )
        }
        // Lag is a product promise (~2 s), so it is a guardrail too: buying CPU
        // back by sending bigger portions would show up here first.
        metrics.live_lag_median_s = sampleStat(
            outcomes.map(\.lagMedianSeconds), tolerance: "+0.5", direction: .lower
        )
    }
    print("Wrote \(latestURL.path)")
}

private func report(_ o: LiveHarness.Outcome) {
    let a = o.accuracy
    print(String(format: "  audio: %.1fs", o.audioSeconds))
    print(String(format: "  sidecar: %.2f cores, %.1f Gcycles/audio-s, peak RSS %.0f MB",
                 o.sidecarCPUCores, o.sidecarGigacyclesPerAudioSecond, o.sidecarPeakRSSMB))
    print(String(format: "  harness: %.2f cores", o.appCPUCores))
    print(String(format: "  fed: %.3f of offered frames", o.framesFedRatio))
    print(String(format: "  WER %.3f (S%d D%d I%d of %d) · coverage %.3f · lag %.2fs",
                 a.wer, a.substitutions, a.deletions, a.insertions, a.referenceWords,
                 a.coverage, o.lagMedianSeconds))
    if let attribution = a.attributionAccuracy {
        print(String(format: "  attribution: %.3f of %d matched words", attribution, a.matches))
    }
    // Which words, not just how many: the difference between a word lost and a
    // word arriving mangled is the whole decision about accepting a saving.
    if !a.deletedWords.isEmpty {
        print("  lost: " + a.deletedWords.joined(separator: ", "))
    }
    if !a.substitutedWords.isEmpty {
        let pairs = a.substitutedWords.map { "\($0.reference)→\($0.hypothesis)" }
        print("  mangled: " + pairs.joined(separator: ", "))
    }
    print("  turns:")
    for turn in o.transcript.turns {
        let who = turn.channel == .owner ? "owner " : "remote"
        print("    [\(turn.timestamp)] \(who) \(turn.text)")
    }
}
