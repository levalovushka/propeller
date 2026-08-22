// Trace → journal, for the lab. Runs the shipped decision over an
// `axprobe trace` JSONL file and prints what `tools/diarize-lab/saer-journal.py`
// scores.
//
//   swift run -c release CallWindowJournalLab трасса.jsonl [--spread 2.0]
//       [--min-run 2] [--muted "звук выключен,muted"] > journal.json
//
// **Two rulers, and only one of them measures the product.** `spans` folds the
// ledger into runs, and the ruler then asks which run *covers* a line — that is
// how the lab has always scored. The app asks a different question: `name(at:)`,
// the nearest sample within a second, with the owner's tile excluded. The two
// disagree exactly at boundaries, which is where attribution is hard, so scoring
// spans measured a rule that was never shipped (TAILS, 2026-08-20).
//
// So with `--utts` the tool answers per line instead, through the shipped
// `LiveSpeaker` itself — not a copy of its logic:
//
//   swift run -c release CallWindowJournalLab трасса.jsonl \
//       --utts ../../tools/diarize-lab/utts/<id>.sys.utts.json \
//       --owner-utts <микрофонные реплики>.json > journal.json
//
// `--owner-utts` is not optional in practice: `name(at:)` stays silent until the
// owner's tile is locked, and the lock needs the owner's mic turns. Without it
// every line comes back unnamed — honestly, and uselessly.
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
let silences = CallWindowJournal.silenceCounts(from: polls, tuning: tuning)

struct SaerSpan: Encodable {
    let speaker: String
    let start: Double
    let end: Double
}

/// One line as the **app** would label it: the nearest sample within a second,
/// owner excluded. Empty speaker = the journal stayed silent, which in the
/// product means the line goes to diarization — not that the journal was wrong.
struct Label: Encodable {
    let start: Double
    let end: Double
    let speaker: String
}

struct Utterance: Decodable {
    let start: Double
    let end: Double
}

func utterances(_ path: String) -> [Utterance] {
    guard let data = FileManager.default.contents(atPath: path) else {
        die("не читается \(path)")
    }
    guard let list = try? JSONDecoder().decode([Utterance].self, from: data) else {
        die("не разбирается как [{start,end}]: \(path)")
    }
    return list
}

/// The shipped machine, fed the whole trace once. The feeding order is load-bearing
/// (`noteOwnerTurn` credits overlap retroactively), so it is written in one place:
/// every answer below — labels, owner, mute share — comes off this one ledger.
func warmed(ownerTurns: [Utterance]) -> CallWindowJournal.LiveSpeaker {
    var live = CallWindowJournal.LiveSpeaker(tuning: tuning)
    for poll in polls.sorted(by: { $0.t < $1.t }) { live.take(poll) }
    for turn in ownerTurns { live.noteOwnerTurn(start: turn.start, end: turn.end) }
    return live
}

/// The by-line answer, produced by the shipped machine rather than a copy of it.
func labels(utts: [Utterance], from live: CallWindowJournal.LiveSpeaker) -> [Label] {
    utts.map { utt in
        let mid = (utt.start + utt.end) / 2
        return Label(start: utt.start, end: utt.end, speaker: live.name(at: mid) ?? "")
    }
}

struct Output: Encodable {
    let polls: Int
    /// Polls that yielded no name, by reason — the lab preview of the §8.4
    /// telemetry: a dual-monitor Zoom must not read as an empty desk.
    let silences: [String: Int]
    let spans: [SaerSpan]
    /// Present only with `--utts`. This is the one the product would give.
    let labels: [Label]?
    /// Whose tile the machine decided is the owner's, and how the owner's own
    /// mute looked — both free here, and both otherwise invisible in the lab.
    let ownerZoomName: String?
    let ownerMutedTurns: [String: Int]?
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var byLine: [Label]?
var ownerName: String?
var ownerMuted: [String: Int]?
if let uttsPath = flag("utts") {
    let owner = flag("owner-utts").map(utterances) ?? []
    if owner.isEmpty {
        FileHandle.standardError.write(Data(
            ("предупреждение: без --owner-utts замок владельца не защёлкнется, "
             + "и каждая строка вернётся безымянной\n").utf8))
    }
    let live = warmed(ownerTurns: owner)
    byLine = labels(utts: utterances(uttsPath), from: live)
    ownerName = live.ownerZoomName
    let share = live.ownerMutedTurnShare
    ownerMuted = ["muted": share.muted, "judged": share.judged]
}

let output = Output(
    polls: polls.count,
    silences: Dictionary(uniqueKeysWithValues: silences.map { ($0.key.rawValue, $0.value) }),
    spans: spans.map { SaerSpan(speaker: $0.name, start: $0.start, end: $0.end) },
    labels: byLine,
    ownerZoomName: ownerName,
    ownerMutedTurns: ownerMuted
)
print(String(decoding: try encoder.encode(output), as: UTF8.self))
