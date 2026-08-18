// diarize-probe — гоняет только диаризатор, без ASR вокруг, и считает DER.
//
// Инструмент разработчика. В приложение не уезжает, в бандл не попадает.
// Существует ради одного: перемерить FluidAudio на размеченной встрече, поменяв
// одну ручку, и увидеть число. Конфиг здесь — тот же `OfflineDiarizerConfig()`,
// что зовёт `TranscriptionService.diarize`, поэтому «как сейчас» получается
// запуском без флагов.
//
//   probe run  <wav> --out hyp.json [--threshold 0.6] [--min-speakers 2] ...
//   probe der  --ref ref.json --hyp hyp.json [--collar 0.25] [--scope ref]
//
// `prepareModels()` не зовётся никогда — она убивает процесс на macOS 14
// (см. meeting-recorder/CLAUDE.md). Модели грузятся двумя публичными половинами,
// ровно как в приложении.

import CoreML
import FluidAudio
import Foundation

// MARK: - Ввод-вывод

struct Span: Codable {
    var speaker: String
    var start: Double
    var end: Double
}

struct RunOutput: Codable {
    var wav: String
    var seconds: Double
    var wallSeconds: Double
    var rtf: Double
    var config: [String: String]
    var spans: [Span]
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func flag(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func has(_ name: String, in args: [String]) -> Bool {
    args.contains("--" + name)
}

func loadSpans(_ path: String) -> [Span] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        die("нет файла: \(path)")
    }
    // Приняты оба вида: голый массив пролётов и вывод `probe run`.
    if let spans = try? JSONDecoder().decode([Span].self, from: data) { return spans }
    if let run = try? JSONDecoder().decode(RunOutput.self, from: data) { return run.spans }
    die("не разобрал \(path): ни массив пролётов, ни вывод probe run")
}

// MARK: - Диаризация

@available(macOS 14.0, *)
func runDiarize(_ args: [String]) async {
    guard let wav = args.first(where: { !$0.hasPrefix("--") }) else { die("нужен путь к wav") }
    let url = URL(fileURLWithPath: wav)

    var config = OfflineDiarizerConfig()
    var described: [String: String] = [:]

    func note(_ key: String, _ value: String) { described[key] = value }

    if let v = flag("threshold", in: args), let d = Double(v) {
        config.clustering.threshold = d
        note("threshold", v)
    }
    if let v = flag("min-speakers", in: args), let n = Int(v) {
        config.clustering.minSpeakers = n
        note("minSpeakers", v)
    }
    if let v = flag("max-speakers", in: args), let n = Int(v) {
        config.clustering.maxSpeakers = n
        note("maxSpeakers", v)
    }
    if let v = flag("num-speakers", in: args), let n = Int(v) {
        config.clustering.numSpeakers = n
        note("numSpeakers", v)
    }
    if let v = flag("min-segment", in: args), let d = Double(v) {
        config.embedding.minSegmentDurationSeconds = d
        note("minSegmentDuration", v)
    }
    if let v = flag("step-ratio", in: args), let d = Double(v) {
        config.segmentation.stepRatio = d
        note("stepRatio", v)
    }
    if let v = flag("window", in: args), let d = Double(v) {
        config.segmentation.windowDurationSeconds = d
        note("windowDuration", v)
    }
    if has("keep-overlap", in: args) {
        config.embedding.excludeOverlap = false
        note("excludeOverlap", "false")
    }
    if has("overlapping-output", in: args) {
        config.postProcessing.exclusiveSegments = false
        note("exclusiveSegments", "false")
    }
    if has("zero-vote-reembed", in: args) {
        let seconds = Double(flag("zero-vote-seconds", in: args) ?? "0.4") ?? 0.4
        config.zeroVoteReembed = .init(enabled: true, minDurationSeconds: seconds)
        note("zeroVoteReembed", "on/\(seconds)")
    }
    if let v = flag("min-gap", in: args), let d = Double(v) {
        config.postProcessing.minGapDurationSeconds = d
        note("minGapDuration", v)
    }
    if let v = flag("fa", in: args), let d = Double(v) {
        config.clustering.warmStartFa = d
        note("Fa", v)
    }
    if let v = flag("fb", in: args), let d = Double(v) {
        config.clustering.warmStartFb = d
        note("Fb", v)
    }

    let manager = OfflineDiarizerManager(config: config)
    let directory = OfflineDiarizerModels.defaultModelsDirectory().standardizedFileURL
    do {
        // Две публичные половины, как в `TranscriptionService.loadDiarizerModels`.
        // `prepareModels()` не звать — она прогревает модель и убивает процесс на macOS 14.
        manager.initialize(models: try await OfflineDiarizerModels.load(from: directory))
    } catch {
        die("модели не загрузились: \(error)")
    }

    let started = Date()
    let result: DiarizationResult
    do {
        result = try await manager.process(url)
    } catch {
        die("диаризация упала: \(error)")
    }
    let wall = Date().timeIntervalSince(started)

    let spans = result.segments
        .map { Span(speaker: "S\($0.speakerId)", start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        .sorted { $0.start < $1.start }
    let audioSeconds = spans.map(\.end).max() ?? 0

    var bySpeaker: [String: Double] = [:]
    for s in spans { bySpeaker[s.speaker, default: 0] += s.end - s.start }
    let order = bySpeaker.sorted { $0.value > $1.value }

    print("=== \(url.lastPathComponent)")
    print(String(format: "  проход %.1f с, RTF %.3f", wall, audioSeconds > 0 ? wall / audioSeconds : 0))
    print("  ручки: " + (described.isEmpty ? "как в приложении" : described.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")))
    print("  голосов \(order.count): " + order.map { String(format: "%@ %.0fс", $0.key, $0.value) }.joined(separator: ", "))

    if let out = flag("out", in: args) {
        let payload = RunOutput(
            wav: url.path,
            seconds: audioSeconds,
            wallSeconds: wall,
            rtf: audioSeconds > 0 ? wall / audioSeconds : 0,
            config: described,
            spans: spans
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(payload).write(to: URL(fileURLWithPath: out))
        print("  → \(out)")
    }
}


// MARK: - Sortformer

/// Sortformer — сквозная диаризация NVIDIA (Apache-совместимая NVIDIA Open Model
/// License), четыре слота спикеров жёстко. Модели тянутся с HuggingFace, поэтому
/// команда сетевая и в лаборатории живёт отдельно от `run`.
@available(macOS 14.0, *)
func runSortformer(_ args: [String]) async {
    guard let wav = args.first(where: { !$0.hasPrefix("--") }) else { die("нужен путь к wav") }
    let url = URL(fileURLWithPath: wav)

    let diarizer = OfflineSortformerDiarizer()
    do {
        try await diarizer.initializeFromHuggingFace()
    } catch {
        die("модели Sortformer не загрузились: \(error)")
    }

    let started = Date()
    let timeline: DiarizerTimeline
    do {
        timeline = try diarizer.processComplete(audioFileURL: url)
    } catch {
        die("Sortformer упал: \(error)")
    }
    let wall = Date().timeIntervalSince(started)

    var spans: [Span] = []
    for (index, speaker) in timeline.speakers {
        for seg in speaker.finalizedSegments {
            spans.append(Span(speaker: "S\(index + 1)", start: Double(seg.startTime), end: Double(seg.endTime)))
        }
    }
    spans.sort { $0.start < $1.start }
    let audioSeconds = spans.map(\.end).max() ?? 0

    var bySpeaker: [String: Double] = [:]
    for s in spans { bySpeaker[s.speaker, default: 0] += s.end - s.start }
    let order = bySpeaker.sorted { $0.value > $1.value }

    print("=== \(url.lastPathComponent) · sortformer")
    print(String(format: "  проход %.1f с, RTF %.3f", wall, audioSeconds > 0 ? wall / audioSeconds : 0))
    print("  голосов \(order.count): " + order.map { String(format: "%@ %.0fс", $0.key, $0.value) }.joined(separator: ", "))

    if let out = flag("out", in: args) {
        let payload = RunOutput(
            wav: url.path,
            seconds: audioSeconds,
            wallSeconds: wall,
            rtf: audioSeconds > 0 ? wall / audioSeconds : 0,
            config: ["engine": "sortformer-offline-v2.1"],
            spans: spans
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(payload).write(to: URL(fileURLWithPath: out))
        print("  → \(out)")
    }
}

// MARK: - DER

/// Пролёты гипотезы, обрезанные по речи эталона.
///
/// Эталон размечен по репликам ASR, значит «тишины» в нём нет: всё, что вне его
/// пролётов, — не молчание, а незнание. Считать там ложные тревоги — считать
/// собственную разметку. Поэтому гипотеза сначала пересекается с эталоном, и
/// остаётся ровно та составляющая DER, которая нам и нужна, — путаница.
func clip(_ hyp: [Span], to ref: [Span]) -> [Span] {
    var out: [Span] = []
    for h in hyp {
        for r in ref {
            let start = max(h.start, r.start)
            let end = min(h.end, r.end)
            if end - start > 0.001 {
                out.append(Span(speaker: h.speaker, start: start, end: end))
            }
        }
    }
    return out.sorted { $0.start < $1.start }
}

func runDER(_ args: [String]) {
    guard let refPath = flag("ref", in: args), let hypPath = flag("hyp", in: args) else {
        die("нужны --ref и --hyp")
    }
    let collar = Double(flag("collar", in: args) ?? "0") ?? 0
    let ref = loadSpans(refPath)
    var hyp = loadSpans(hypPath)
    let scope = flag("scope", in: args) ?? "ref"
    if scope == "ref" { hyp = clip(hyp, to: ref) }

    let result = DiarizationDER.compute(
        ref: ref.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) },
        hyp: hyp.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) },
        frameStep: 0.01,
        collar: collar
    )

    let refSpeech = result.totalRefSpeech
    print(String(format: "  эталон %.0f с речи, collar %.2f, область %@", refSpeech, collar, scope))
    print(String(format: "  DER %.1f %%  (путаница %.1f, пропуск %.1f, ложная %.1f)",
                 result.der * 100,
                 refSpeech > 0 ? result.confusion / refSpeech * 100 : 0,
                 refSpeech > 0 ? result.miss / refSpeech * 100 : 0,
                 refSpeech > 0 ? result.falseAlarm / refSpeech * 100 : 0))
    let mapping = result.mapping.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }
    print("  сопоставление: " + (mapping.isEmpty ? "пусто" : mapping.joined(separator: " ")))
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    die("probe run <wav> [--out f] | probe sortformer <wav> [--out f] | probe der --ref f --hyp f")
}
let rest = Array(argv.dropFirst())

switch command {
case "run":
    if #available(macOS 14.0, *) {
        await runDiarize(rest)
    } else {
        die("нужна macOS 14")
    }
case "sortformer":
    if #available(macOS 14.0, *) {
        await runSortformer(rest)
    } else {
        die("нужна macOS 14")
    }
case "der":
    runDER(rest)
default:
    die("неизвестная команда: \(command)")
}
