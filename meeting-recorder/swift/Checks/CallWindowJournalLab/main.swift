// Trace → journal, for the lab. Runs the shipped decision
// (`CallWindowJournal.spans`) over an `axprobe trace` JSONL file and prints
// spans in the shape `tools/diarize-lab/saer-journal.py` scores:
// {"spans":[{"speaker","start","end"}]}.
//
//   swift run -c release CallWindowJournalLab трасса.jsonl [--spread 2.0]
//       [--min-run 2] [--muted "звук выключен,muted"] > journal.json
//
// The flags exist to re-answer threshold questions in the lab; the defaults
// are the documented ones from `CallWindowJournal.Tuning` — chosen, not
// measured, until gate Г0 (plan-speaker-tags.md §3).

import Foundation
import PropellerPure

let args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let flagValueIndexes = Set(args.indices.filter { $0 > 0 && args[$0 - 1].hasPrefix("--") })
guard let path = args.indices
    .first(where: { !args[$0].hasPrefix("--") && !flagValueIndexes.contains($0) })
    .map({ args[$0] })
else {
    die("нужна трасса: CallWindowJournalLab трасса.jsonl [--spread X] [--min-run N] [--muted a,b]")
}

guard let data = FileManager.default.contents(atPath: path) else {
    die("не читается \(path)")
}

var tuning = CallWindowJournal.Tuning()
if let v = flag("spread"), let d = Double(v) { tuning.areaSpreadRatio = d }
if let v = flag("min-run"), let n = Int(v) { tuning.minRunPolls = n }
if let v = flag("muted") {
    tuning.mutedMarkers = v.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
    }
}

let polls = CallWindowJournal.polls(fromJSONL: data)
let spans = CallWindowJournal.spans(from: polls, tuning: tuning)

struct SaerSpan: Encodable {
    let speaker: String
    let start: Double
    let end: Double
}

struct Output: Encodable {
    let polls: Int
    let spans: [SaerSpan]
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let output = Output(
    polls: polls.count,
    spans: spans.map { SaerSpan(speaker: $0.name, start: $0.start, end: $0.end) }
)
print(String(decoding: try encoder.encode(output), as: UTF8.self))
