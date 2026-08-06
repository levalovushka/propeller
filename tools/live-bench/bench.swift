import Foundation
import AVFoundation

// Стриминг одного стема в gigastt с заданным размером куска. Печатает только
// финалы: их текст, размер и задержку от конца звука до ответа.
// usage: swift wsbench.swift <wav> <port> <chunkMs> <limitSeconds> <label>

let args = CommandLine.arguments
let file = args[1]
let port = args[2]
let chunkMs = Double(args[3])!
let limit = Double(args[4])!
let label = args[5]

let start = Date()

func pcm16(from url: URL) throws -> [Int16] {
    let f = try AVAudioFile(forReading: url)
    let inFormat = f.processingFormat
    let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    let frames = AVAudioFrameCount(f.length)
    guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return [] }
    try f.read(into: input)
    guard let conv = AVAudioConverter(from: inFormat, to: out) else { return [] }
    let cap = AVAudioFrameCount(Double(frames) * out.sampleRate / inFormat.sampleRate + 4096)
    guard let output = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return [] }
    var used = false
    var err: NSError?
    _ = conv.convert(to: output, error: &err) { _, status in
        if used { status.pointee = .endOfStream; return nil }
        used = true; status.pointee = .haveData; return input
    }
    guard let p = output.int16ChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: Int(output.frameLength)))
}

final class Sink: @unchecked Sendable {
    let lock = NSLock()
    var finals: [(text: String, end: Double, at: Double)] = []
    func add(_ t: String, _ end: Double, _ at: Double) {
        lock.lock(); finals.append((t, end, at)); lock.unlock()
    }
}
let sink = Sink()

struct Msg: Decodable {
    let type: String
    let text: String?
    struct W: Decodable { let start: Double?; let end: Double? }
    let words: [W]?
}

let session = URLSession(configuration: .ephemeral)
let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
task.resume()

func receive() {
    task.receive { result in
        guard case .success(let m) = result else { return }
        if case .string(let s) = m, let d = s.data(using: .utf8),
           let msg = try? JSONDecoder().decode(Msg.self, from: d),
           msg.type == "final", let text = msg.text, !text.isEmpty {
            let end = msg.words?.compactMap(\.end).max() ?? 0
            sink.add(text, end, Date().timeIntervalSince(start))
        }
        receive()
    }
}
receive()
task.send(.string(#"{"type":"configure","sample_rate":16000}"#)) { _ in }

let samples = try pcm16(from: URL(fileURLWithPath: file))
let chunk = Int(16000 * chunkMs / 1000)
var i = 0
while i < samples.count, Double(i) / 16000 < limit {
    let end = min(i + chunk, samples.count)
    let data = Array(samples[i..<end]).withUnsafeBufferPointer { Data(buffer: $0) }
    task.send(.data(data)) { _ in }
    i = end
    Thread.sleep(forTimeInterval: chunkMs / 1000)
}
// Дать движку договорить.
Thread.sleep(forTimeInterval: 4)

sink.lock.lock()
let finals = sink.finals
sink.lock.unlock()
let words = finals.flatMap { $0.text.split(separator: " ") }
let lags = finals.map { $0.at - $0.end }
print("=== \(label) (кусок \(Int(chunkMs)) мс)")
print("сегментов: \(finals.count), слов: \(words.count), слов на сегмент: "
      + String(format: "%.1f", Double(words.count) / Double(max(1, finals.count))))
print("задержка от конца фразы: медиана " + String(format: "%.2f с", lags.sorted()[max(0, lags.count/2)]))
print("ТЕКСТ: " + finals.map(\.text).joined(separator: " "))
task.cancel()
