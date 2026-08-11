import AVFoundation
import Foundation
import os
import PropellerMetrics
import PropellerPure

/// Unified logging — near-zero cost when unused, no unbounded file growth
/// (plan-optimization E6). Kept as a free function so existing call sites stay.
func debugLog(_ msg: String) {
    Logger(subsystem: "app.propeller", category: "debug").debug("\(msg, privacy: .public)")
}

@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    // Mic recording (legacy AVAudioRecorder path).
    private var avRecorder: AVAudioRecorder?
    /// Эхоподавления здесь нет и не будет: Apple VPIO перенастраивает **общее**
    /// устройство ввода, и его AGC достаётся всем, кто держит микрофон, —
    /// тестировщик стал почти не слышен собеседникам (удалено 2026-07-28,
    /// `9c0ae44`). Эхо динамика в микрофонной дорожке остаётся; с экрана его
    /// убирает `EchoDedup` — по тексту, а не фильтром на звуке.
    private(set) var startTime: Date?
    private(set) var recordingID: String?
    private(set) var filePath: URL?
    private(set) var duration: TimeInterval = 0

    /// Захват на общих часах: одно агрегатное устройство пишет обе дорожки
    /// сэмпл в сэмпл (`ProcessTapCapture`). Nil, когда запись идёт запасным
    /// путём — тогда работает всё, что ниже.
    private var tapCapture: AnyObject?
    /// Каким путём пишется текущая запись.
    private(set) var capturePath: CapturePath = .microphoneOnly
    /// Есть ли у текущего захвата вторая дорожка. Решает, открывать ли живому
    /// слою вторую сессию: сессия, в которую никогда не придёт кадр, закроется
    /// по простою и будет переподключаться всю встречу ни за чем.
    private(set) var capturesSystemAudio = false
    /// Каким путём была записана предыдущая — уезжает в отчёт и телеметрию.
    private(set) var lastStopPath: CapturePath?

    /// Куда пишется системная дорожка текущей записи. Nil на микрофонном пути.
    private var systemAudioURL: URL?
    /// Осталось ради интерфейса: на общих часах жёсткого отказа старта нет —
    /// путь либо поднялся, либо запись честно микрофонная.
    @Published var systemAudioWarning: String?
    /// Set in `stop()` from the actual `.sys.wav` stem (empty / missing).
    private(set) var lastStopWasMicOnly = false
    /// Seconds of microphone audio already on disk when the system stem opened —
    /// i.e. where that stem starts on this recording's timeline (`StemTimeline`).
    /// Nil until the first system buffer lands, and forever on mic-only.
    private(set) var systemStemOffset: TimeInterval?
    /// The same number, kept past `stop()` so the caller can persist it with the
    /// recording: a crash-recovered re-mix must not have to guess it again.
    private(set) var lastStopSystemStemOffset: TimeInterval?
    /// Whether the finished recording's system stem came from the meeting app or
    /// from the whole machine.
    private(set) var lastStopWasAppScoped: Bool?
    /// Non-nil if the mic writer isn't actually producing frames shortly after
    /// start (e.g. input device disappeared). Unlike system audio, the mic is
    /// the essential source — this is surfaced immediately, not tagged post-hoc.
    @Published var micCaptureWarning: String?

    /// Кадры обеих дорожек 16 кГц моно по мере захвата — то, из чего живой слой
    /// делает транскрипт (`LiveTranscriptService`). Зовётся с очереди записи, а
    /// не с главного актора: звук туда не ходит.
    ///
    /// Ставится до `start()`; переживает паузу, потому что пауза — это состояние
    /// записи, а не её конец. На микрофонном пути не зовётся никогда: буферов
    /// там нет, и это одна из причин, по которой живой слой на нём отсутствует.
    var onLiveFrames: ((_ mic: [Float], _ system: [Float]) -> Void)?

    /// Запись идёт, но звук в неё сейчас не попадает.
    ///
    /// Не «стоп с продолжением»: файл остаётся тем же, дорожки — теми же, и
    /// после снятия паузы кадры ложатся сразу за уже записанными. Пауза просто
    /// не существует внутри записи — ни секундой тишины, ни сдвигом дорожек.
    @Published private(set) var isPaused = false
    /// Сколько всего простояли на паузе, и с какого момента стоим сейчас.
    /// Из этого считается `elapsed`: таймер на экране обязан совпадать с тем,
    /// сколько звука в файле.
    private var pausedTotal: TimeInterval = 0
    private var pausedSince: Date?

    /// Rolling history of mic audio levels (0–1) for waveform display.
    /// Уровни звука по времени. **Не `@Published` намеренно.**
    ///
    /// Их единственный потребитель — лопасть в чёлке, и она берёт последнее
    /// значение замыканием, когда сама решит рисовать
    /// (`NotchController.face(on:)` → `NotchFace.level`). Публикация же
    /// объявлялась 17.3 раза в секунду (замерено, `--live-probe`) — и каждая
    /// заставляла SwiftUI пересобирать всё, что подписано на recorder, ради
    /// значения, которого никто не ждал. Дефект P4 в его самой дорогой части.
    var micLevelHistory: [Float] = []
    /// Rolling history of system audio levels (0–1) for waveform display.
    var systemLevelHistory: [Float] = []
    private var meterTimer: Timer?
    private static let historySize = 50
    /// When false, metering is paused (window closed / accessory) — recording continues (E5).
    private var meteringDesired = false

    var elapsed: TimeInterval {
        guard let start = startTime, isRecording else { return 0 }
        let standing = pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, Date().timeIntervalSince(start) - pausedTotal - standing)
    }

    func start() throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        systemAudioWarning = nil
        micCaptureWarning = nil
        lastStopWasMicOnly = false
        systemStemOffset = nil
        isPaused = false
        pausedTotal = 0
        pausedSince = nil
        debugLog("[AudioRecorder] start() called — captureSystemAudio=\(Preferences.shared.captureSystemAudio)")

        let recordingsDir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let id = Self.makeID()
        let micURL = recordingsDir.appendingPathComponent("\(id).mic.wav")
        let finalURL = recordingsDir.appendingPathComponent("\(id).wav")
        let sysURL = recordingsDir.appendingPathComponent("\(id).sys.wav")

        // Какой путь захвата берём. Список, а не один ответ: подняться путь
        // может только на живой системе, и «поднялся» — это факт, а не прогноз
        // (`CapturePathPolicy`).
        let ladder = CapturePathPolicy.ladder(CaptureCapabilities(
            wantsSystemAudio: Preferences.shared.captureSystemAudio,
            sharedClockReady: ProcessTapCapture.isReady
        ))
        debugLog("[AudioRecorder] лестница путей: \(ladder.map(\.rawValue).joined(separator: " → "))")

        if ladder.first == .processTap,
           startTapCapture(id: id, micURL: micURL, sysURL: sysURL) {
            capturePath = .processTap
            recordingID = id
            filePath = finalURL
            startTime = Date()
            isRecording = true
            armMicIntegrityWatchdog()
            if meteringDesired { startMetering() }
            return
        }
        // Общие часы не поднялись — остаётся микрофон. Это состояние записи, а
        // не отказ: человеку про него говорят (`lastStopWasMicOnly`), и звук
        // его собственного голоса он получит в любом случае.
        capturePath = .microphoneOnly

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        // Plain AVAudioRecorder only. Apple's voice processing (VPIO) used to be
        // offered here as "подавлять эхо динамика", and it reconfigures the shared
        // input device rather than just our own capture: one tester became almost
        // inaudible to everyone else on the call. A recorder must never degrade
        // the meeting it is recording, so the option and its engine are gone.
        avRecorder = try AVAudioRecorder(url: micURL, settings: settings)
        avRecorder?.isMeteringEnabled = true
        guard let recorder = avRecorder, recorder.record() else {
            throw RecorderError.failedToStart
        }

        recordingID = id
        filePath = finalURL
        startTime = Date()
        isRecording = true
        armMicIntegrityWatchdog()

        // Metering starts only when the UI asks for it (window open) — E5.
        if meteringDesired {
            startMetering()
        }
    }

    private func startTapCapture(id: String, micURL: URL, sysURL: URL) -> Bool {
        // Свежий снимок, а не отладенное состояние детектора: между входом в
        // звонок и его подтверждением проходит до двух опросов.
        let platformID = MeetingDetector.captureSnapshot().platformID
        let capture = ProcessTapCapture(micURL: micURL, systemURL: sysURL, callPlatformID: platformID)
        capture.onIssue = { message in
            NSLog("[AudioRecorder] tap capture note: \(message)")
        }
        // Захваченный замыканием, а не прочитанный через `self`: кадры идут с
        // очереди записи, и лезть за ним на главный актор двадцать раз в
        // секунду незачем.
        if let sink = onLiveFrames {
            capture.onLiveFrames = { mic, system in sink(mic, system) }
        }
        do {
            try capture.start()
        } catch {
            // Не баннер: запись всё равно будет, просто микрофонная.
            NSLog("[AudioRecorder] общие часы не поднялись (\(error.localizedDescription)) — иду запасным путём")
            // Разрешение могли отозвать. Запоминаем отказ, чтобы следующая
            // запись не тратила на ту же проверку начало встречи.
            Preferences.shared.sharedClockCaptureWorks = false
            return false
        }
        Preferences.shared.sharedClockCaptureWorks = true
        tapCapture = capture
        capturesSystemAudio = capture.capturesSystemAudio
        systemAudioURL = sysURL
        // Дорожки выровнены по построению: сдвига, который раньше приходилось
        // измерять и хранить, у этого пути просто нет.
        systemStemOffset = 0
        NSLog("[AudioRecorder] запись на общих часах, id=\(id)")
        return true
    }

    // MARK: - Пауза

    /// Остановить приём звука, не заканчивая запись.
    ///
    /// На общих часах пауза — это «кадры не берём»: курсор перепривязывается на
    /// возобновлении, и в файле пауза не оставляет следа. На микрофонном пути то
    /// же самое делает сам `AVAudioRecorder`.
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pausedSince = Date()
        if let capture = tapCapture as? ProcessTapCapture {
            capture.setPaused(true)
        } else {
            avRecorder?.pause()
        }
    }

    func resume() {
        guard isRecording, isPaused else { return }
        if let since = pausedSince {
            pausedTotal += Date().timeIntervalSince(since)
        }
        pausedSince = nil
        isPaused = false
        if let capture = tapCapture as? ProcessTapCapture {
            capture.setPaused(false)
        } else {
            // `record()` на приостановленном рекордере — это именно
            // «продолжить»: файл тот же, дописывается с конца.
            _ = avRecorder?.record()
        }
    }

#if GALLERY
    /// Пауза без записи — кадр «Запись — пауза». Настоящую поставить нечем:
    /// нужен живой захват.
    func galleryPosePaused(_ paused: Bool) { isPaused = paused }
#endif

    /// Enable/pause live level metering. Recording itself is unaffected (E5).
    func setMeteringDesired(_ desired: Bool) {
        meteringDesired = desired
        guard isRecording else { return }
        if desired {
            if meterTimer == nil { startMetering() }
        } else {
            stopMetering()
        }
    }

    func stop() async throws -> (id: String, url: URL, duration: TimeInterval) {
        if let capture = tapCapture as? ProcessTapCapture {
            return try await stopTapCapture(capture)
        }
        stopMetering()
        let recordedDuration: TimeInterval
        recordedDuration = avRecorder?.currentTime ?? 0
        avRecorder?.stop()
        let dur = recordedDuration > 0
            ? recordedDuration
            : Date().timeIntervalSince(startTime ?? Date())
        let id = recordingID ?? ""
        let finalURL = filePath ?? URL(fileURLWithPath: "")
        let recordingsDir = finalURL.deletingLastPathComponent()
        let micURL = recordingsDir.appendingPathComponent("\(id).mic.wav")

        duration = dur
        isRecording = false
        avRecorder = nil
        recordingID = nil
        filePath = nil
        startTime = nil

        // Системного стема на этом пути нет вовсе: он остался единственно для
        // случая, когда общие часы не поднялись. Значит и сводить нечего —
        // микрофон копируется в финал.
        lastStopSystemStemOffset = nil
        systemStemOffset = nil
        lastStopWasAppScoped = nil
        lastStopPath = .microphoneOnly
        lastStopWasMicOnly = Preferences.shared.captureSystemAudio

        await Self.produceFinalMix(
            micURL: micURL, sysURL: nil, finalURL: finalURL, systemStemOffset: 0
        )

        return (id, finalURL, dur)
    }

    private func stopTapCapture(_ capture: ProcessTapCapture) async throws
        -> (id: String, url: URL, duration: TimeInterval) {
        stopMetering()
        let id = recordingID ?? ""
        let finalURL = filePath ?? URL(fileURLWithPath: "")
        let recordingsDir = finalURL.deletingLastPathComponent()
        let micURL = recordingsDir.appendingPathComponent("\(id).mic.wav")
        let sysURL = systemAudioURL
        let wallClock = Date().timeIntervalSince(startTime ?? Date())

        isRecording = false
        tapCapture = nil
        systemAudioURL = nil
        recordingID = nil
        filePath = nil
        startTime = nil

        let report = await capture.stop()
        NSLog("[AudioRecorder] tap report: \(report.logLine)")

        // Длительность берём у часов захвата, а не у стенных: это то же число,
        // что лежит в файле, и расхождение между ними — как раз то, что раньше
        // приходилось вылавливать по остаточным признакам.
        let captured = report.deviceSampleRate > 0
            ? Double(report.framesCaptured) / report.deviceSampleRate : 0
        let dur = captured > 0 ? captured : wallClock
        duration = dur

        // Сдвига нет по построению — стемы складываются с нулевого кадра.
        lastStopSystemStemOffset = 0
        systemStemOffset = nil
        lastStopWasAppScoped = report.hasSystemAudio ? report.scopedToCall : nil
        lastStopWasMicOnly = Preferences.shared.captureSystemAudio && !report.capturedUsableStem
        lastStopPath = .processTap
        systemAudioWarning = nil

        await Self.produceFinalMix(
            micURL: micURL, sysURL: report.hasSystemAudio ? sysURL : nil,
            finalURL: finalURL, systemStemOffset: 0
        )
        return (id, finalURL, dur)
    }

    /// Confirms the mic writer is actually producing frames shortly after
    /// start, rather than silently discovering at stop time that nothing was
    /// captured (e.g. the input device disappeared right after `record()`
    /// returned true). Checks recorded-duration progress, not just
    /// `isRecording`, since a stalled writer can stay "running" with no data.
    private func armMicIntegrityWatchdog() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isRecording else { return }
            let progressed: TimeInterval
            if let capture = self.tapCapture as? ProcessTapCapture {
                let report = capture.report()
                progressed = report.deviceSampleRate > 0
                    ? Double(report.framesCaptured) / report.deviceSampleRate : 0
            } else if let rec = self.avRecorder {
                progressed = rec.currentTime
            } else {
                progressed = 0
            }
            if progressed < 1.5 {
                let message = "Микрофон не пишет — в первые секунды аудио не записалось. Проверьте устройство ввода."
                debugLog("[AudioRecorder] WARNING: \(message) (progressed=\(progressed)s)")
                self.micCaptureWarning = message
            }
        }
    }

    private static func makeID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    // MARK: - Audio Level Metering

    /// Как часто на самом деле приходит уровень.
    ///
    /// Замер, а не догадка: лопасть в чёлке питается этими отсчётами, и от их
    /// частоты зависит, чувствуется ли её ход ровным. По коду выходило «раз в
    /// несколько десятков миллисекунд» — но период зависит от размера буфера
    /// Core Audio, который выбирает система, а не мы. Пишется раз в десять
    /// секунд, чтобы не быть шумом в логе.
    private var levelTicks = 0
    private var levelWindowStart: Date?
    private static let levelReportWindow: TimeInterval = 10

    private func noteLevelTick() {
        let now = Date()
        guard let started = levelWindowStart else {
            levelWindowStart = now
            levelTicks = 1
            return
        }
        levelTicks += 1
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= Self.levelReportWindow else { return }
        let perSecond = Double(levelTicks) / elapsed
        debugLog(String(
            format: "[AudioRecorder] уровень: %.1f отсчётов/с (%.0f мс между ними)",
            perSecond, 1000 / max(perSecond, 0.001)
        ))
        Analytics.signal("Capture.levelRate", value: perSecond)
        levelWindowStart = now
        levelTicks = 0
    }

    private func startMetering() {
        micLevelHistory = Array(repeating: 0, count: Self.historySize)
        systemLevelHistory = Array(repeating: 0, count: Self.historySize)

        // На общих часах обе шкалы приходят из одного буфера, а значит и в
        // индикаторе они описывают один и тот же момент — таймер тут не нужен
        // и врать ему нечем.
        if let capture = tapCapture as? ProcessTapCapture {
            levelTicks = 0
            levelWindowStart = nil
            capture.levelCallback = { [weak self] mic, system in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording, self.meteringDesired else { return }
                    self.append(mic, to: &self.micLevelHistory)
                    self.append(system, to: &self.systemLevelHistory)
                    self.noteLevelTick()
                }
            }
            return
        }

        // ~10 Hz (was 12.5) — enough for a smooth waveform, less MainActor churn (E5/S6).
        let interval: TimeInterval = 0.1
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.meteringDesired else { return }
                let normalized: Float
                if let rec = self.avRecorder {
                    rec.updateMeters()
                    let db = rec.averagePower(forChannel: 0)
                    normalized = max(0, min(1, (db + 50) / 50))
                } else {
                    return
                }
                self.micLevelHistory.append(normalized)
                if self.micLevelHistory.count > Self.historySize {
                    self.micLevelHistory.removeFirst(self.micLevelHistory.count - Self.historySize)
                }
                // Микрофонный путь: системной дорожки нет, но шкала должна
                // идти вровень с микрофонной, иначе волна поедет.
                if true {
                    self.systemLevelHistory.append(0)
                    if self.systemLevelHistory.count > Self.historySize {
                        self.systemLevelHistory.removeFirst(self.systemLevelHistory.count - Self.historySize)
                    }
                }
            }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func append(_ level: Float, to history: inout [Float]) {
        history.append(level)
        if history.count > Self.historySize {
            history.removeFirst(history.count - Self.historySize)
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        if let capture = tapCapture as? ProcessTapCapture {
            capture.levelCallback = nil
        }
    }

    // MARK: - Offline mix of mic + system audio

    /// Produces the final 16kHz mono WAV at `finalURL` by summing mic + system audio.
    /// If the system-audio file is missing or empty, the mic recording is copied verbatim.
    /// Raw stems are retained next to the final file so speaker matching can
    /// infer whether a diarized voice came mostly from mic or system audio.
    /// Offline mix of mic (+ optional system) stems into the final 16 kHz mono WAV.
    /// Also used by crash-recovery when only `.mic.wav` survived (plan-optimization C3).
    static func produceFinalMix(
        micURL: URL,
        sysURL: URL?,
        finalURL: URL,
        systemStemOffset: TimeInterval = 0
    ) async {
        let fm = FileManager.default
        // Есть стем — микшуем. Здесь стоял третий по счёту порог «слышимости»
        // (`hasAudibleContent`), и он отвечал на вопрос, которого не задавали:
        // тишину микшировать не вредно — `MixGain` на тихом стеме возвращает 1,
        // то есть складывает тишину с микрофоном и ничего не усиливает. Зато
        // порог мог выбросить настоящую, но тихую дальнюю сторону целиком.
        // Заодно ушло чтение всего стема ради одной строки в лог.
        let hasSys: Bool = {
            guard let u = sysURL else { return false }
            guard let attrs = try? fm.attributesOfItem(atPath: u.path),
                  let size = attrs[.size] as? NSNumber else { return false }
            return size.intValue > 4096
        }()

        if !hasSys {
            // Стема нет вовсе (mic-only) — копируем микрофон в финал.
            _ = try? fm.removeItem(at: finalURL)
            do { try fm.copyItem(at: micURL, to: finalURL) } catch {
                debugLog("[AudioRecorder] copy mic → final failed: \(error)")
            }
            return
        }

        // Mix using AVAudioEngine offline rendering.
        do {
            try await PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.mix) {
                try await Self.mix(
                    micURL: micURL, sysURL: sysURL!, finalURL: finalURL,
                    systemStemOffset: systemStemOffset
                )
            }
        } catch {
            debugLog("[AudioRecorder] offline mix failed, falling back to mic only: \(error)")
            _ = try? fm.removeItem(at: finalURL)
            try? fm.copyItem(at: micURL, to: finalURL)
        }
    }

    private static func mix(
        micURL: URL,
        sysURL: URL,
        finalURL: URL,
        systemStemOffset: TimeInterval
    ) async throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let sysFile = try AVAudioFile(forReading: sysURL)

        // Final format: same as existing pipeline — 16kHz mono.
        let targetSR: Double = 16_000
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSR,
            channels: 1,
            interleaved: false
        )!
        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: targetSR,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        _ = try? FileManager.default.removeItem(at: finalURL)
        let outFile = try AVAudioFile(forWriting: finalURL, settings: writeSettings)

        let micMono = try Self.readAndResample(file: micFile, to: outFormat)
        let sysMono = try Self.readAndResample(file: sysFile, to: outFormat)
        let sysGain = Self.systemMixGain(mic: micMono, system: sysMono)
        debugLog("[AudioRecorder] Mixing mic + system with systemGain=\(String(format: "%.2f", sysGain))")

        // The system stem does not start when the microphone does — it opens
        // `systemStemOffset` seconds in, and summing both from index zero is what
        // put the far end into the recording twice, half a second apart
        // (`StemTimeline`, docs/ECHO_AND_MIX_EXPERIMENTS.md).
        let micN = Int(micMono.frameLength)
        let sysN = Int(sysMono.frameLength)
        let sysStart = StemTimeline.systemStartFrame(
            offsetSeconds: systemStemOffset, sampleRate: targetSR
        )
        let n = AVAudioFrameCount(
            StemTimeline.mixedFrameCount(
                micFrames: micN, systemFrames: sysN, systemStartFrame: sysStart
            )
        )
        debugLog("[AudioRecorder] mixing mic=\(micN) sys=\(sysN) frames, system stem placed at \(sysStart) frames (\(Int(systemStemOffset * 1000)) ms)")

        // Sum with soft clamp. System audio can arrive quieter than the mic,
        // so apply a bounded automatic gain before clamping.
        guard n > 0, let mixed = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: n) else {
            throw RecorderError.failedToMix
        }
        mixed.frameLength = n
        guard let mixPtr = mixed.floatChannelData?[0],
              let micPtr = micMono.floatChannelData?[0],
              let sysPtr = sysMono.floatChannelData?[0] else {
            throw RecorderError.failedToMix
        }
        for i in 0..<Int(n) {
            let m = i < micN ? micPtr[i] : 0
            let j = i - sysStart
            let s = (j >= 0 && j < sysN) ? sysPtr[j] * sysGain : 0
            var v = m + s
            if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
            mixPtr[i] = v
        }
        try outFile.write(from: mixed)
    }

    private static func systemMixGain(mic: AVAudioPCMBuffer, system: AVAudioPCMBuffer) -> Float {
        let micStats = bufferStats(mic)
        let systemStats = bufferStats(system)
        return MixGain.systemMixGain(
            micRMS: micStats.rms, micPeak: micStats.peak,
            systemRMS: systemStats.rms, systemPeak: systemStats.peak
        )
    }

    private static func bufferStats(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        guard let data = buffer.floatChannelData else { return (0, 0) }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return (0, 0) }
        var sumSq: Float = 0
        var peak: Float = 0
        var count = 0
        for channel in 0..<channels {
            let p = data[channel]
            for frame in 0..<frames {
                let value = p[frame]
                sumSq += value * value
                peak = max(peak, abs(value))
                count += 1
            }
        }
        guard count > 0 else { return (0, 0) }
        return (sqrt(sumSq / Float(count)), peak)
    }

    private static func readAndResample(file: AVAudioFile, to outFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            return AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1)!
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw RecorderError.failedToMix
        }
        try file.read(into: input)

        if inFormat.sampleRate == outFormat.sampleRate && inFormat.channelCount == 1 {
            return input
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError.failedToMix
        }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw RecorderError.failedToMix
        }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw convError ?? RecorderError.failedToMix
        }
        return output
    }

    enum RecorderError: LocalizedError {
        case alreadyRecording, failedToStart, failedToMix
        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Уже идёт запись"
            case .failedToStart: return "Не удалось начать запись"
            case .failedToMix: return "Не удалось свести микрофон и системный звук"
            }
        }
    }
}

// MARK: - Voice-Processed Mic Capture
