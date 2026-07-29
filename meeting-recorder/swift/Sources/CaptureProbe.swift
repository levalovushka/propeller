import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// # Куда на самом деле уходит звук звонка
///
/// Запускается как `--capture-probe` из бинарника внутри `.app`, а не отдельным
/// инструментом, по одной причине: разрешение на запись экрана выдано **этому**
/// бандлу. Отдельная утилита попросила бы его заново, у Терминала, и мерила бы
/// уже другую систему.
///
/// Отвечает на вопрос, из-за которого появился откат на захват всего экрана:
/// видит ли ScreenCaptureKit процесс, который реально играет звук звонка, и
/// ловит ли app-scoped фильтр хоть что-нибудь. `aomhost` у Zoom окон не имеет, а
/// список приложений мы строим с `onScreenWindowsOnly: true` — то есть из тех, у
/// кого окно есть. Если гипотеза верна, app-scoped всё это время слушал тишину.
///
/// Ничего не записывает и не трогает архив: считает буферы и уровни, печатает
/// таблицу, выходит.
@available(macOS 14.0, *)
enum CaptureProbe {

    static let flag = "--capture-probe"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    /// Сколько слушать каждый вариант фильтра.
    private static let trialSeconds: UInt64 = 6

    /// Отчёт пишется файлом, потому что запускать пробу приходится через
    /// `open -a`, а не из терминала: разрешение на запись экрана привязано к
    /// бандлу, и у процесса, запущенного из Терминала, его нет — SCK просто
    /// вернёт пустой список источников.
    static let reportURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Meeting Recorder/capture-probe.txt")

    private static var lines: [String] = []

    private static func out(_ text: String = "") {
        print(text)
        lines.append(text)
    }

    private static func flushReport() {
        let body = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? body.write(to: reportURL, atomically: true, encoding: .utf8)
        print("\nОтчёт: \(reportURL.path)")
    }

    static func run() async {
        lines = []
        out("""

        ╭───────────────────────────────────────────────────────────────╮
        │  Проба захвата звука.                                          │
        │                                                                │
        │  Нужно, чтобы ЗВУК ИГРАЛ ИМЕННО ИЗ ZOOM и не смолкал ~25 с.    │
        │  В соло-встрече проще всего так:                               │
        │    · Zoom → Настройки → Звук → «Проверить динамик»              │
        │      (тестовый сигнал играет по кругу), либо                    │
        │    · зайти в ту же встречу с телефона и говорить в него.        │
        │                                                                │
        │  Проба сама подождёт, пока звук появится.                      │
        ╰───────────────────────────────────────────────────────────────╯
        """)
        out("Разрешение «Запись экрана» (preflight): \(CGPreflightScreenCaptureAccess())")

        await listProcesses()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            out("НЕ УДАЛОСЬ получить список источников: \(error.localizedDescription)")
            out("Если запускали бинарник из терминала — так и будет: разрешение выдано бандлу.")
            out("Запускайте: open -a Propeller --args --capture-probe")
            flushReport()
            return
        }
        guard let display = content.displays.first else {
            out("НЕ УДАЛОСЬ найти дисплей.")
            flushReport()
            return
        }

        let zoomish = content.applications.filter { isZoomish($0) }
        let windowed = (try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ))?.applications.filter { isZoomish($0) } ?? []

        var trials: [(String, SCContentFilter)] = []

        if !windowed.isEmpty {
            trials.append((
                "app-scoped, только окна (как в проде): \(describe(windowed))",
                SCContentFilter(display: display, including: windowed, exceptingWindows: [])
            ))
        } else {
            out("\n⚠️  Среди приложений с окнами Zoom не найден — прод-путь сразу ушёл бы в display-wide.")
        }

        if !zoomish.isEmpty, zoomish.count != windowed.count {
            trials.append((
                "app-scoped, включая процессы без окон: \(describe(zoomish))",
                SCContentFilter(display: display, including: zoomish, exceptingWindows: [])
            ))
        }

        trials.append((
            "display-wide (весь экран)",
            SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        ))

        guard await waitForAudio(display: display) else {
            out("\nЗвука на машине так и не появилось — мерить нечего.")
            out("Включите тестовый сигнал динамика в Zoom и запустите пробу заново.")
            flushReport()
            return
        }

        out("\nСлушаю каждый вариант по \(trialSeconds) с…\n")
        var results: [(String, ProbeSink.Result)] = []
        for (name, filter) in trials {
            out("  → \(name)")
            let result = await listen(filter: filter)
            out("     \(result.line)")
            results.append((name, result))
        }

        verdict(results)
        flushReport()
    }

    /// Ждёт, пока на машине вообще появится звук. Без этого все три варианта
    /// отчитаются тишиной, и отличить «фильтр не ловит» от «нечего ловить»
    /// будет нельзя — первая же проба на это и напоролась.
    private static func waitForAudio(display: SCDisplay) async -> Bool {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        for attempt in 1...12 {
            let probe = await listen(filter: filter, seconds: 3)
            if probe.audibleBuffers > 0 {
                out("\nЗвук пошёл (пик \(String(format: "%.4f", probe.peak))) — начинаю замер. Не выключайте его ещё полминуты.")
                return true
            }
            if attempt == 1 {
                out("\nЖду звука из Zoom… включите «Проверить динамик» в настройках звука.")
            }
        }
        return false
    }

    // MARK: - Процессы

    private static func listProcesses() async {
        for onScreenOnly in [true, false] {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: onScreenOnly
            ) else { continue }
            let zoomish = content.applications.filter { isZoomish($0) }
            out("")
            out("SCShareableContent(onScreenWindowsOnly: \(onScreenOnly)) — всего приложений: \(content.applications.count)")
            out("  подходящих под Zoom: \(zoomish.isEmpty ? "нет" : String(zoomish.count))")
            for app in zoomish {
                out("    pid \(app.processID)  \(app.bundleIdentifier)  «\(app.applicationName)»")
            }
        }
    }

    /// Всё, что может иметь отношение к звонку: сам Zoom и его хелперы, которые
    /// в `MeetingPlatform.callHelperProcesses` уже описаны для детектора.
    private static func isZoomish(_ app: SCRunningApplication) -> Bool {
        let bundle = app.bundleIdentifier.lowercased()
        let name = app.applicationName.lowercased()
        for needle in ["zoom", "aomhost", "caphost"] {
            if bundle.contains(needle) || name.contains(needle) { return true }
        }
        return false
    }

    private static func describe(_ apps: [SCRunningApplication]) -> String {
        apps.map { "\($0.bundleIdentifier)#\($0.processID)" }.joined(separator: ", ")
    }

    // MARK: - Один замер

    private static func listen(filter: SCContentFilter, seconds: UInt64? = nil) async -> ProbeSink.Result {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        config.sampleRate = 48_000
        config.channelCount = 2

        let sink = ProbeSink()
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: .global())
            try await stream.startCapture()
        } catch {
            return ProbeSink.Result(error: "не стартовал: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: (seconds ?? trialSeconds) * 1_000_000_000)
        try? await stream.stopCapture()
        return sink.result
    }

    // MARK: - Вывод

    private static func verdict(_ results: [(String, ProbeSink.Result)]) {
        out("\n─────────── что это значит ───────────")
        let prod = results.first { $0.0.hasPrefix("app-scoped, только окна") }?.1
        let full = results.first { $0.0.hasPrefix("app-scoped, включая") }?.1
        let wide = results.first { $0.0.hasPrefix("display-wide") }?.1

        // Сначала проверяем, было ли вообще что ловить: без этого «app-scoped
        // молчит» ничего не значит.
        if let wide, wide.audibleBuffers == 0 {
            out("• Звук пропал по ходу замера — display-wide тоже пуст. Остальные строки недействительны,")
            out("  повторите пробу с непрерывным сигналом.")
            out("──────────────────────────────────────")
            return
        }

        if let prod, prod.audibleBuffers > 0 {
            out("• Прод-путь ловит звук. Значит откат по тишине лечит не прицел, а что-то ещё.")
        } else if prod != nil {
            out("• Прод-путь звука НЕ поймал — гипотеза подтверждается: мы целимся в окно, а звук у процесса.")
        }
        if let full, full.audibleBuffers > 0 {
            out("• Фильтр с процессами без окон работает → чинится внутри SCK, process taps не нужны.")
        } else if full != nil {
            out("• Даже с хелперами app-scoped молчит → SCK по процессу нам звонок не отдаёт, смотреть в сторону process taps.")
        }
        out("──────────────────────────────────────")
    }
}

/// Считает буферы и уровни, ничего не пишет на диск.
@available(macOS 14.0, *)
private final class ProbeSink: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Result {
        var callbacks = 0
        var frames = 0
        var audibleBuffers = 0
        var peak: Float = 0
        var error: String?

        var line: String {
            if let error { return "❌ \(error)" }
            if callbacks == 0 { return "❌ буферов нет вовсе" }
            if audibleBuffers == 0 {
                return "⚠️  буферы идут (\(callbacks)), но всё тишина: кадров \(frames), пик \(String(format: "%.5f", peak))"
            }
            return "✅ звук есть: буферов \(callbacks), со звуком \(audibleBuffers), кадров \(frames), пик \(String(format: "%.5f", peak))"
        }
    }

    private let lock = NSLock()
    private var value = Result()

    var result: Result {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let peak = Self.peak(of: sampleBuffer)
        lock.lock()
        value.callbacks += 1
        value.frames += frames
        value.peak = max(value.peak, peak)
        // Тот же порог, по которому прод решает «слышимое» — чтобы проба и
        // сторож отвечали на вопрос одинаково.
        if peak > 0.0005 { value.audibleBuffers += 1 }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        value.error = error.localizedDescription
        lock.unlock()
    }

    private static func peak(of sampleBuffer: CMSampleBuffer) -> Float {
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = abl.mBuffers.mData else { return 0 }
        let count = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        let samples = data.bindMemory(to: Float.self, capacity: count)
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(samples[i])) }
        return peak
    }
}
