// Замерный драйвер: собрать ленту из двух дорожек ровно тем кодом, который
// уезжает в приложение (StemAssembly.assemble). Диаризации здесь нет — для
// метрики принадлежности имена спикеров дальней стороны не важны, важно, чьи
// слова стоят в строке.
//
// Сборка (из meeting-recorder/swift):
//   swiftc -O PropellerPure/*.swift ../../tools/echo-probe/assemble/main.swift -o /tmp/assemble
// Запуск:
//   /tmp/assemble <каталог> <имя> [окно]
//   читает <имя>.{mic,sys}.srt (сегменты) и <имя>.{mic,sys}.json (слова с таймингами)
//   пишет  <имя>.dedup.srt      — микрофон без эха
//          <имя>.assembled.srt  — лента
//          <имя>.assembled.json — та же лента с именами (для owner-echo.py)
//          <имя>.transcript.md  — в вёрстке приложения (для recap-lab)
//          <имя>.trims.txt      — что именно вынуто, с контекстом собеседника
import Foundation

struct Cue {
    let start: Double
    let end: Double
    let text: String
}

func parseSRT(_ url: URL) -> [Cue] {
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("нет файла: \(url.path)\n".utf8))
        exit(1)
    }
    var out: [Cue] = []
    for block in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
        let lines = block.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2, lines[1].contains("-->") else { continue }
        let parts = lines[1].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let a = clock(parts[0]), let b = clock(parts[1]) else { continue }
        let body = lines.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !body.isEmpty { out.append(Cue(start: a, end: b, text: body)) }
    }
    return out
}

func clock(_ v: String) -> Double? {
    let parts = v.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
    guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
    return h * 3600 + m * 60 + s
}

/// Слова с таймингами из `gigastt -f json` — то же, что приложение получает от
/// сайдкара в `segments[].words`.
func parseWords(_ url: URL) -> [ASRWord] {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let words = json["words"] as? [[String: Any]] else { return [] }
    return words.compactMap { w in
        guard let text = w["word"] as? String,
              let start = w["start"] as? Double,
              let end = w["end"] as? Double else { return nil }
        return ASRWord(start: start, end: end, text: text)
    }
}

func stamp(_ t: Double) -> String {
    let ms = Int((t * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
}

func writeSRT(_ cues: [Cue], to url: URL) {
    let body = cues.enumerated().map { i, c in
        "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n"
    }.joined(separator: "\n")
    try! body.write(to: url, atomically: true, encoding: .utf8)
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let name = CommandLine.arguments[2]
let window = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : StemAssembly.echoWindow

let mic = parseSRT(dir.appendingPathComponent("\(name).mic.srt"))
let sys = parseSRT(dir.appendingPathComponent("\(name).sys.srt"))
let micWords = parseWords(dir.appendingPathComponent("\(name).mic.json"))
let farWords = parseWords(dir.appendingPathComponent("\(name).sys.json"))

let micLines = mic.map { EchoDedup.Line(start: $0.start, end: $0.end, text: $0.text) }
let farLines = sys.map { StemMerge.Line(start: $0.start, end: $0.end, speaker: "Собеседник", text: $0.text) }
let heard = sys.map { EchoDedup.Line(start: $0.start, end: $0.end, text: $0.text) }

let owner = StemAssembly.ownerLines(
    mic: micLines, micWords: micWords, farSide: heard, farWords: farWords, window: window
)
let assembled = StemAssembly.assemble(
    mic: micLines, micWords: micWords, ownerName: "Левон", farSide: farLines, farWords: farWords,
    window: window
)

writeSRT(owner.map { Cue(start: $0.start, end: $0.end, text: $0.text) },
         to: dir.appendingPathComponent("\(name).dedup.srt"))
writeSRT(assembled.map { Cue(start: $0.start, end: $0.end, text: $0.text) },
         to: dir.appendingPathComponent("\(name).assembled.srt"))

// Тот же результат с именами — для разбора, кто именно оказался «смешанным».
let tagged = assembled.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker, "text": $0.text] as [String: Any] }
try! JSONSerialization.data(withJSONObject: tagged, options: [.prettyPrinted])
    .write(to: dir.appendingPathComponent("\(name).assembled.json"))

// Что именно вынуто из реплик — построчно, чтобы посмотреть глазами, а не
// поверить проценту.
var trims: [String] = []
for line in micLines {
    let after = StemAssembly.withoutEcho(line, words: micWords, farWords: farWords, window: window)
    let kept = after.map(\.text).joined(separator: " ⋯ ")
    guard kept != line.text else { continue }
    let t = Int(line.start)
    let around = heard
        .filter { $0.end > line.start - 1.5 && $0.start < line.end + 1.5 }
        .map(\.text).joined(separator: " ")
    trims.append("""
    [\(t / 60):\(String(format: "%02d", t % 60))]
      было:      \(line.text)
      стало:     \(kept.isEmpty ? "— снято целиком —" : kept)
      собеседник: \(around)
    """)
}
try! trims.joined(separator: "\n").write(
    to: dir.appendingPathComponent("\(name).trims.txt"), atomically: true, encoding: .utf8)

// Транскрипт в том виде, в котором его читает конспект: реплики подряд одного
// человека собираются, если между ними меньше пяти секунд — так же, как
// `TranscriptionService.collapseConsecutiveSameSpeaker`, иначе лаборатория
// сравнивала бы «до» и «после» в разной вёрстке.
var turns: [StemMerge.Line] = []
for line in assembled {
    if let last = turns.last, last.speaker == line.speaker, line.start - last.end <= 5 {
        turns[turns.count - 1] = StemMerge.Line(
            start: last.start, end: line.end, speaker: last.speaker,
            text: last.text + " " + line.text
        )
    } else {
        turns.append(line)
    }
}
let markdown = turns.map { turn -> String in
    let m = Int(turn.start) / 60, s = Int(turn.start) % 60
    return "**\(turn.speaker)** · \(String(format: "%02d:%02d", m, s))\n\n\(turn.text)"
}.joined(separator: "\n\n")
try! ("# \(name)\n\n## Transcript\n\n" + markdown + "\n").write(
    to: dir.appendingPathComponent("\(name).transcript.md"), atomically: true, encoding: .utf8)

func words(_ text: String) -> Int { TranscriptAccuracy.words(in: text).count }
let micWordCount = mic.reduce(0) { $0 + words($1.text) }
let ownerWords = owner.reduce(0) { $0 + words($1.text) }
print("микрофон: \(mic.count) реплик (\(micWordCount) слов) · дальняя сторона: \(sys.count) реплик")
print("владелец после снятия эха: \(owner.count) реплик (\(ownerWords) слов) · лента \(assembled.count) строк")
