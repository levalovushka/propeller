import AVFoundation
import Foundation
import PropellerPure

/// # What the live layer costs, and what it is worth
///
/// The batch harness measures the pass that runs after a meeting. This one
/// measures the part that runs *during* it — two recognition sessions, both
/// tracks, for the whole call. That is where the machine's day goes:
/// `GigasttSidecar.swift:332` records "~1 core on two sessions" from a live
/// stream, against ~0.03 RTF for the offline pass. Nothing in `benchmarks/`
/// covered it, so every claim about making the app cheaper was unfalsifiable.
///
/// ## Why it streams in real time
///
/// Because the cost being measured is not throughput. Feeding a 27 s clip as
/// fast as the socket accepts it measures how quickly the engine *can* chew;
/// the meeting instead hands it 50 ms of audio 20 times a second for an hour,
/// and the encoder re-runs on a 2 s window each time. Only the second shape
/// tells you what a laptop lid feels like.
///
/// Frame sizes are the app's, not round numbers: the capture drain timer fires
/// every 50 ms (`ProcessTapCapture.startDraining`), and a session buffers to 2 s
/// before sending (`GigasttLiveSession.chunkFrames`) because 2 s is where WER
/// bottoms out — 9.7 % against 25 % at 200 ms (`tools/live-bench/README.md`).
///
/// ## Why quality is measured in the same run
///
/// So that "cheaper" cannot be bought with silence. Three quality numbers come
/// out beside the cost ones (`TranscriptAccuracy`), and `coverage` is the one
/// that matters most: a gate that stops feeding the engine mid-speech can
/// *improve* WER while deleting half the meeting.
///
/// Not measured here, deliberately: our own end of the pipe is metered too
/// (`live.app_cpu_cores`), but the harness is not the app — it has no AppKit, no
/// SwiftUI tree to rebuild, no disk writer. Do not read that number as the app's.
enum LiveHarness {

    /// 50 ms — one capture drain tick.
    static let ingestChunkSeconds = 0.05
    /// 2 s — one session portion.
    static let sessionChunkSeconds = 2.0
    static let sampleRate = 16_000

    struct Outcome {
        var audioSeconds: Double
        var sidecarCPUCores: Double
        var sidecarGigacyclesPerAudioSecond: Double
        var sidecarPeakRSSMB: Double
        var appCPUCores: Double
        var framesFedRatio: Double
        var wer: Double
        var coverage: Double
        var attributionAccuracy: Double?
        var lagMedianSeconds: Double
        var transcript: LiveTranscript
        var accuracy: TranscriptAccuracy.Report
    }

    // MARK: - Run

    static func run(fixtureDir: URL, port: Int, warmup: Bool) async throws -> Outcome {
        let mic = try samples(fixtureDir.appendingPathComponent("final.mic.wav"))
        let systemStem = try? samples(fixtureDir.appendingPathComponent("final.sys.wav"))
        let system = systemStem ?? []
        guard !mic.isEmpty else { throw BenchError.missingFixture("final.mic.wav (empty)") }

        let reference = try Reference.load(fixtureDir: fixtureDir)
        let audioSeconds = Double(max(mic.count, system.count)) / Double(sampleRate)

        let sidecar = try await LiveSidecar.start(port: port)
        defer { sidecar.stop() }

        if warmup {
            // The first portion after boot pays for lazily built kernels and a
            // cold CoreML cache; measuring it as "the cost of a meeting" reads
            // as a 2x regression on a machine that merely rebooted.
            print("warm-up: 4 s of the mic stem")
            _ = try await stream(
                mic: Array(mic.prefix(4 * sampleRate)),
                system: Array(system.prefix(min(system.count, 4 * sampleRate))),
                port: port, meter: nil
            )
        }

        let sampler = ProcessSampler(pid: sidecar.pid)
        guard let sidecarBefore = ProcessCost.of(pid: sidecar.pid),
              let appBefore = ProcessCost.of(pid: getpid())
        else { throw BenchError.costUnavailable }
        sampler.start()

        let streamed = try await stream(mic: mic, system: system, port: port, meter: sampler)

        sampler.stop()
        guard let sidecarAfter = ProcessCost.of(pid: sidecar.pid),
              let appAfter = ProcessCost.of(pid: getpid()),
              let sidecarSpent = sidecarAfter.since(sidecarBefore),
              let appSpent = appAfter.since(appBefore)
        else { throw BenchError.costUnavailable }

        let hypothesis = TranscriptAccuracy.words(in: streamed.transcript)
        let accuracy = TranscriptAccuracy.compare(hypothesis: hypothesis, reference: reference.words)

        return Outcome(
            audioSeconds: audioSeconds,
            sidecarCPUCores: sidecarSpent.cpuSeconds / audioSeconds,
            sidecarGigacyclesPerAudioSecond: Double(sidecarSpent.cycles) / 1e9 / audioSeconds,
            sidecarPeakRSSMB: sampler.peakResidentMB,
            appCPUCores: appSpent.cpuSeconds / audioSeconds,
            framesFedRatio: streamed.framesFedRatio,
            wer: accuracy.wer,
            coverage: accuracy.coverage,
            attributionAccuracy: accuracy.attributionAccuracy,
            lagMedianSeconds: streamed.lagMedianSeconds,
            transcript: streamed.transcript,
            accuracy: accuracy
        )
    }

    // MARK: - Streaming

    struct Streamed {
        var transcript: LiveTranscript
        var framesFedRatio: Double
        var lagMedianSeconds: Double
    }

    /// Feeds both stems in real time, exactly as the app's live layer does, and
    /// folds the answers into a `LiveTranscript` — the product's own assembly,
    /// so segment joining and turn splitting are not re-implemented here.
    static func stream(
        mic: [Float], system: [Float], port: Int, meter: ProcessSampler?
    ) async throws -> Streamed {
        let hasSystem = !system.isEmpty
        let collector = Collector()

        let micSession = LiveWSSession(port: port, channel: .owner, collector: collector)
        let systemSession = hasSystem
            ? LiveWSSession(port: port, channel: .remote, collector: collector)
            : nil
        micSession.open()
        systemSession?.open()

        // The engine will not accept audio before it answers `ready`.
        try await micSession.waitUntilReady()
        try await systemSession?.waitUntilReady()

        let chunk = Int(Double(sampleRate) * ingestChunkSeconds)
        let total = max(mic.count, system.count)
        // Mirrors `LoudnessLog` in LiveTranscriptService: the same windows, from
        // the same frames, so the echo rule below sees what the app sees.
        var dominance = StemDominance()
        var offset = 0
        // Lag is counted from the first frame of audio, so the clock starts here
        // — after `ready`, which on a cold sidecar can take seconds.
        collector.beginClock()
        let start = Date()

        while offset < total {
            let end = min(offset + chunk, total)
            let micSlice = slice(mic, offset, end)
            let systemSlice = hasSystem ? slice(system, offset, end) : []

            let from = Double(offset) / Double(sampleRate)
            let to = Double(end) / Double(sampleRate)
            dominance.note(from: from, to: to, mic: rms(micSlice), system: rms(systemSlice))

            micSession.feed(micSlice)
            systemSession?.feed(systemSlice)
            offset = end

            // Real time, measured against the start rather than accumulated
            // sleeps: 20 ticks a second drift visibly over an hour.
            let due = start.addingTimeInterval(Double(offset) / Double(sampleRate))
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }

        micSession.flush()
        systemSession?.flush()
        // A decision lands ~0.2 s after the audio; the tail portion needs its
        // turn too. Four seconds is what tools/live-bench waits.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        _ = meter

        // A run with a dropped socket describes a clip that was partly never
        // recognized. Reporting it as a measurement is worse than not measuring.
        if let failure = micSession.failure ?? systemSession?.failure {
            micSession.close()
            systemSession?.close()
            throw BenchError.sessionFailed(failure)
        }

        micSession.close()
        systemSession?.close()

        // Same rule as the app (`LiveTranscriptService.absorb`): a mic-session
        // decision from a stretch the owner did not dominate is the far side
        // heard through the speakers, and it is not shown. Applying it here
        // keeps the measured text equal to the shipped text.
        var transcript = LiveTranscript()
        var echoDropped = 0
        for final in collector.finals.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            if final.channel == .owner,
               dominance.ownerSpoke(from: final.start, to: final.end) == false {
                echoDropped += 1
                continue
            }
            transcript.absorb(
                channel: final.channel, start: final.start, end: final.end, text: final.text
            )
        }
        if echoDropped > 0 { print("  echo rule dropped \(echoDropped) mic finals") }

        let fed = micSession.framesFed + (systemSession?.framesFed ?? 0)
        let offered = micSession.framesOffered + (systemSession?.framesOffered ?? 0)
        let lags = collector.finals.map { $0.receivedAt - $0.end }.sorted()

        return Streamed(
            transcript: transcript,
            framesFedRatio: offered > 0 ? Double(fed) / Double(offered) : 1,
            lagMedianSeconds: lags.isEmpty ? 0 : lags[lags.count / 2]
        )
    }

    private static func slice(_ samples: [Float], _ from: Int, _ to: Int) -> [Float] {
        guard from < samples.count else { return [] }
        return Array(samples[from..<min(to, samples.count)])
    }

    /// Same arithmetic as `LoudnessLog.rms`.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: - Audio

    /// 16 kHz mono float frames — what the capture hands the live layer.
    static func samples(_ url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)
        else { return [] }
        try file.read(into: input)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false
        ) else { return [] }

        if inFormat.sampleRate == target.sampleRate, inFormat.channelCount == 1,
           let data = input.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: data, count: Int(input.frameLength)))
        }

        guard let converter = AVAudioConverter(from: inFormat, to: target) else { return [] }
        let capacity = AVAudioFrameCount(
            Double(frames) * target.sampleRate / inFormat.sampleRate + 4096
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return [] }
        var consumed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    // MARK: - Reference

    struct Reference {
        var words: [TranscriptAccuracy.Word]

        /// The ground truth, with each word carrying the track it should have
        /// arrived on. Order comes from `reference-transcript.txt` (which is in
        /// speaking order); the track comes from `reference-speakers.json`, where
        /// each turn records the stem it was mixed into.
        static func load(fixtureDir: URL) throws -> Reference {
            let textURL = fixtureDir.appendingPathComponent("reference-transcript.txt")
            let text = try String(contentsOf: textURL, encoding: .utf8)

            var channelForTurn: [String: LiveTranscript.Channel] = [:]
            let speakersURL = fixtureDir.appendingPathComponent("reference-speakers.json")
            if let data = try? Data(contentsOf: speakersURL),
               let decoded = try? JSONDecoder().decode(Speakers.self, from: data) {
                for speaker in decoded.speakers {
                    let channel: LiveTranscript.Channel = speaker.stem_hint == "mic" ? .owner : .remote
                    for turn in speaker.turns {
                        channelForTurn[key(turn.text)] = channel
                    }
                }
            }

            var words: [TranscriptAccuracy.Word] = []
            for line in text.split(whereSeparator: \.isNewline) {
                let channel = channelForTurn[key(String(line))]
                words += TranscriptAccuracy.words(in: String(line))
                    .map { TranscriptAccuracy.Word(text: $0, channel: channel) }
            }
            guard !words.isEmpty else { throw BenchError.missingFixture(textURL.path) }
            return Reference(words: words)
        }

        /// Turns are matched to lines by their normalized words, so punctuation
        /// or spacing differences between the two files do not silently drop
        /// the channel and turn attribution into "unknown".
        private static func key(_ text: String) -> String {
            TranscriptAccuracy.words(in: text).joined(separator: " ")
        }

        private struct Speakers: Decodable {
            struct Speaker: Decodable {
                struct Turn: Decodable { let text: String }
                let stem_hint: String
                let turns: [Turn]
            }
            let speakers: [Speaker]
        }
    }
}
