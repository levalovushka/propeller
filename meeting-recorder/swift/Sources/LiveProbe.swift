import AppKit
import AVFoundation
import Combine
import Foundation
import PropellerPure

/// # Успевает ли живой слой за встречей
///
/// Живая строка держится на утверждениях, которые проверяются только замером:
/// что сессия поднимается, что кадры доходят, что текст успевает за речью и что
/// читаемо получается не только у того, кто говорит в микрофон.
///
/// Гадать тут нельзя ровно по той же причине, что и в `TapProbe`: промах
/// молчаливый. Сессия, которая не поднялась, выглядит как встреча, на которой
/// все молчали.
///
/// Проба берёт **настоящий** `AudioRecorder` и **настоящий**
/// `LiveTranscriptService` — то есть меряет тот путь, которым пойдёт встреча, а
/// не его модель. Запись после замера удаляется: в архиве от пробы не остаётся
/// ничего.
///
/// ```
/// open -a Propeller --args --live-probe 30
/// ```
/// Пока идёт — говорите и включите что-нибудь звучащее: одна дорожка проверяет
/// микрофон, другая систему, и без второго источника вторая сессия ответит
/// молчанием, которое не отличить от поломки.
@MainActor
enum LiveProbe {

    static let flag = "--live-probe"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    /// Сколько слушать. Двадцать пять секунд — столько, чтобы движок успел
    /// отдать несколько финалов, и не столько, чтобы человек ушёл.
    private static var seconds: Double {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              let value = Double(args[i + 1]), value > 0 else { return 25 }
        return value
    }

    static let reportURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Meeting Recorder/live-probe.txt")

    private static var lines: [String] = []

    private static func out(_ text: String = "") {
        NSLog("[LiveProbe] %@", text)
        lines.append(text)
        try? FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    static func run() async {
        lines = []
        out("""

        ╭────────────────────────────────────────────────────────────────╮
        │  Проба живого транскрипта, \(Int(seconds)) с.
        │  Говорите в микрофон и включите что-нибудь звучащее — дорожки    │
        │  проверяются обе.                                               │
        ╰────────────────────────────────────────────────────────────────╯
        """)

        await ProcessTapCapture.warmUpIfNeeded()
        out("путь общих часов готов: \(ProcessTapCapture.isReady)")

        do {
            try await GigasttSidecar.shared.ensureReady()
            out("сайдкар поднят")
        } catch {
            out("❌ сайдкар не поднялся: \(error.localizedDescription)")
            out("живого текста не будет — но запись бы шла, и это ровно то, что должно происходить")
        }

        let live = LiveTranscriptService()
        let recorder = AudioRecorder()
        recorder.onLiveFrames = { [live] mic, system in
            live.ingest(mic: mic, system: system)
        }
        do {
            try recorder.start()
        } catch {
            out("❌ запись не началась: \(error.localizedDescription)")
            exitAfterFlush()
            return
        }
        out("путь захвата: \(recorder.capturePath.rawValue), системная дорожка: "
            + (recorder.capturesSystemAudio ? "есть" : "нет"))

        // Сколько раз за встречу источники объявляют изменение. Каждое из них —
        // повод SwiftUI пересобрать всё, что на них подписано, а `MainView`
        // подписан на `AppState` целиком (дефект P4). Считаем то, что можно
        // посчитать точно: сами публикации.
        // Уровни считаются только когда их кто-то показывает
        // (`setMeteringDesired`), поэтому проба включает их сама: иначе она
        // померила бы запись с закрытым окном, а дефект P4 — про открытое.
        recorder.setMeteringDesired(true)
        var publishes = (recorder: 0, live: 0)
        var probes: [AnyCancellable] = []
        probes.append(recorder.objectWillChange.sink { _ in publishes.recorder += 1 })
        probes.append(live.objectWillChange.sink { _ in publishes.live += 1 })

        let started = Date()
        live.begin(
            recordingID: recorder.recordingID ?? "probe",
            hasSystemAudio: recorder.capturesSystemAudio,
            elapsed: 0
        )

        // Замеряем не «пришёл ли текст», а когда именно: задержка до первого
        // слова — единственное, что отличает живую строку от запоздалой.
        var firstTextAt: TimeInterval?
        var lastCount = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let turns = live.transcript.turns
            if firstTextAt == nil, !turns.isEmpty {
                firstTextAt = Date().timeIntervalSince(started)
                out(String(format: "первый текст через %.2f с", firstTextAt!))
            }
            if turns.count != lastCount {
                lastCount = turns.count
                out("реплик: \(turns.count)")
            }
        }

        // Пауза — часть замера: она обязана остановить таймер и не оставить в
        // файле ни секунды тишины.
        recorder.pause()
        live.pause()
        let elapsedAtPause = recorder.elapsed
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let elapsedAfterStanding = recorder.elapsed
        out(String(format: "пауза: таймер %.1f → %.1f с (стоял 3 с)",
                   elapsedAtPause, elapsedAfterStanding))
        recorder.resume()
        live.resume(at: recorder.elapsed)
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        live.stop()
        let turns = live.transcript.turns
        out("\n─── что услышали ───")
        for turn in turns {
            out("  [\(turn.timestamp)] \(turn.channel.rawValue): \(turn.text)")
        }
        if turns.isEmpty {
            out("  ничего. Если при этом было что слушать — смотреть надо на сессии выше.")
        }

        do {
            let result = try await recorder.stop()
            let frames = (try? AVAudioFile(forReading: result.url).length) ?? 0
            out(String(format: "\nзапись: %.2f с по часам захвата, %d кадров в файле (%.2f с)",
                       result.duration, frames, Double(frames) / 16_000))
            out("пауза не должна была попасть в файл: длительность ≈ время замера минус 3 с")
            // Проба ничего не оставляет в архиве.
            let dir = result.url.deletingLastPathComponent()
            for name in [result.url.lastPathComponent,
                         "\(result.id).mic.wav", "\(result.id).sys.wav"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        } catch {
            out("❌ остановка не удалась: \(error.localizedDescription)")
        }

        let seconds = max(1, Date().timeIntervalSince(started))
        out(String(format: "\nпубликаций за %.0f с: recorder %d (%.1f/с), живой слой %d (%.1f/с)",
                   seconds, publishes.recorder, Double(publishes.recorder) / seconds,
                   publishes.live, Double(publishes.live) / seconds))
        out("каждая — повод пересобрать всё, что подписано; MainView подписан на AppState целиком")
        probes.removeAll()

        out("\n─── проба закончена ───")
        exitAfterFlush()
    }

    private static func exitAfterFlush() {
        GigasttSidecar.shared.stop()
        exit(0)
    }
}
