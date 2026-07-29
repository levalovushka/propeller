import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import PropellerPure

/// # Собирается ли агрегат так, как мы думаем
///
/// Захват на общих часах держится на утверждении, которое **нигде не
/// задокументировано**: входные каналы агрегатного устройства идут в порядке
/// «сабдевайсы в порядке композиции, за ними тапы». Советы в интернете на этот
/// счёт друг другу противоречат — один источник уверяет, что тап без реального
/// устройства вывода отдаёт нули, другой ровно так и делает, и у него работает.
///
/// Гадать тут нельзя: промах молчаливый. Файл пишется, размер правильный, а в
/// микрофонной дорожке чужая речь, и узнают об этом, когда сядут слушать.
///
/// Поэтому проба меряет, а не рассуждает: собирает каждый вариант композиции,
/// печатает **пик по каждому каналу отдельно** и даёт человеку сказать в
/// микрофон и включить звук — после чего видно, какой канал чей.
///
/// Живёт в релизном бинарнике, а не отдельной утилитой: разрешение на захват
/// звука выдаётся **бандлу**, и отдельный инструмент мерил бы другую систему.

enum TapProbe {

    static let flag = "--tap-probe"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    static let reportURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Meeting Recorder/tap-probe.txt")

    private static var lines: [String] = []

    /// Через NSLog, а не `print`: пробу приходится запускать `open -a`, а её
    /// stdout уходит в трубу и буферизуется поблочно — на зависшем шаге в файле
    /// не оказывается ровно того, ради чего пробу и запускали.
    private static func out(_ text: String = "") {
        NSLog("[TapProbe] %@", text)
        lines.append(text)
        // Отчёт дописывается сразу, а не в конце: Core Audio умеет встать
        // намертво, и тогда единственное, что нужно от пробы, — последняя
        // строка перед тем, как всё замерло. Она же и терялась.
        flush()
    }

    /// Core Audio умеет вставать намертво внутри `AudioDeviceStart`, и тогда
    /// проба молчит вместо того, чтобы сказать, на чём именно встала. Сторож
    /// не отменяет вызов (Core Audio такого не умеет) — он даёт пробе доложить
    /// и идти дальше.
    /// Откуда звать Core Audio. Гипотеза, ради которой это параметр: образец
    /// Apple (`AudioCap`) делает `AudioDeviceCreateIOProcIDWithBlock` и
    /// `AudioDeviceStart` **с главного потока**, а у нас они висят с потока без
    /// runloop. Проверяется тем же замером, а не рассуждением.
    enum CallSite { case detachedThread, mainThread }

    /// Девяносто секунд, а не пять: первое в жизни процесса открытие входа
    /// Core Audio ждёт решения TCC, и на этой машине оно занимало **шестьдесят
    /// секунд ровно** — после чего всё последующее открывается за 0.02 с.
    /// Короткий сторож принимал это ожидание за смерть и обрывал ровно то, что
    /// надо было дождаться.
    private static func withWatchdog(
        _ label: String, seconds: Double = 90, from site: CallSite = .detachedThread,
        _ body: @escaping () -> OSStatus
    ) async -> OSStatus? {
        await withCheckedContinuation { (continuation: CheckedContinuation<OSStatus?, Never>) in
            let done = NSLock()
            var finished = false
            let startedAt = Date()
            let run = {
                let status = body()
                let elapsed = -startedAt.timeIntervalSinceNow
                if elapsed > 1 {
                    NSLog("[TapProbe] ⏱ %@ вернулся за %.1f с", label, elapsed)
                }
                done.lock()
                let first = !finished
                finished = true
                done.unlock()
                if first { continuation.resume(returning: status) }
            }
            switch site {
            case .detachedThread: Thread.detachNewThread(run)
            case .mainThread: DispatchQueue.main.async(execute: run)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                done.lock()
                let first = !finished
                finished = true
                done.unlock()
                if first {
                    NSLog("[TapProbe] ⏳ %@ не вернулся за %.0f с — считаем зависшим", label, seconds)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func flush() {
        try? FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    static func run() async {
        lines = []
        out("""

        ╭────────────────────────────────────────────────────────────────╮
        │  Проба захвата на общих часах.                                  │
        │                                                                 │
        │  Пока она идёт (~40 с), нужно, чтобы звучало И ТО, И ДРУГОЕ:     │
        │    · говорите в микрофон, не замолкая;                           │
        │    · пусть параллельно играет музыка или видео.                  │
        │                                                                 │
        │  Иначе по пикам каналов будет не отличить микрофон от системы.   │
        ╰────────────────────────────────────────────────────────────────╯
        """)

        describeDevices()
        out("  разрешение на микрофон: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) "
            + "(3 = выдано)")
        describeProcesses()

        // Ступени контроля, снизу вверх: сырое устройство → агрегат из одного
        // микрофона → агрегат с тапом. Если встанет на первой, дело вообще не в
        // тапах, и все выводы выше по стеку были бы о другом.
        await probeRawInputDevice()
        await probeMicOnlyAggregate()

        guard let tap = makeGlobalTap() else {
            out("\n❌ Тап не создался вовсе. Если это первый запуск — система должна была")
            out("   спросить разрешение на запись звука; без него тап молчит и статус не узнать.")
            flush()
            return
        }
        defer { AudioHardwareDestroyProcessTap(tap.id) }

        let format = CoreAudioObjects.tapStreamFormat(tap.id)
        out("\nТап создан: каналов \(format.map { Int($0.mChannelsPerFrame) } ?? -1), "
            + "частота \(format.map { $0.mSampleRate } ?? 0)")

        await probeCompositions(tap: tap)
        await probeRealCapture()
        await probeThroughAudioRecorder()
        await probeDeviceSwitch()
        await probeInputSwitch()
        out("\n─── проба закончена ───")
    }

    /// Человек надевает AirPods посреди звонка. Сегодня системный звук после
    /// этого может тихо пропасть до конца встречи (дефект M3) — здесь это
    /// проверяется настоящим переключением устройства вывода на живой записи.
    ///
    /// Устройство возвращается на место в любом случае: замер не имеет права
    /// оставить человека без звука.
    ///
    /// **Нужны два настоящих устройства.** Виртуальные карты (ZoomAudioDevice и
    /// подобные) основными не становятся: система возвращает `noErr` и оставляет
    /// прежнее. Именно на этом первый прогон и дал ложный вывод «захват пережил
    /// смену устройства» — пережить было нечего. Поэтому переключение читается
    /// обратно, и без него ступень честно объявляет замер недействительным.
    private static func probeDeviceSwitch() async {
        out("\n─── ступень 5: смена устройства вывода посреди записи ───")
        guard let original = CoreAudioObjects.defaultOutputDevice,
              let other = alternativeOutputDevice(besides: original) else {
            out("  второго устройства вывода нет — переключать не на что, пропускаю")
            return
        }
        out("  \(CoreAudioObjects.deviceName(original)) → \(CoreAudioObjects.deviceName(other)) → обратно")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-tap-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let capture = ProcessTapCapture(
            micURL: dir.appendingPathComponent("switch.mic.wav"),
            systemURL: dir.appendingPathComponent("switch.sys.wav"),
            callPlatformID: nil
        )
        capture.onIssue = { out("    ⚠️  \($0)") }
        // Уровни по фазам, а не общий максимум: вопрос ведь не «был ли звук
        // вообще», а «дожила ли дальняя сторона до конца записи».
        let phases = PhaseLevels()
        capture.levelCallback = { mic, system in phases.record(mic: mic, system: system) }
        do { try capture.start() } catch {
            out("  ❌ не стартовал: \(error.localizedDescription)")
            return
        }

        try? await Task.sleep(nanoseconds: 6_000_000_000)
        out("  переключаю…")
        phases.advance()
        guard setDefaultOutputDevice(other) else {
            out("  замер недействителен: устройство переключить не удалось")
            _ = await capture.stop()
            return
        }
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        out("  возвращаю…")
        phases.advance()
        setDefaultOutputDevice(original)
        try? await Task.sleep(nanoseconds: 7_000_000_000)

        let report = await capture.stop()
        // На всякий случай ещё раз: если что-то пошло не так выше, человек
        // должен остаться со своим устройством, а не с нашим.
        setDefaultOutputDevice(original)

        out("  \(report.logLine)")
        for (index, label) in ["до переключения", "на чужом устройстве", "после возврата"].enumerated() {
            let level = phases.snapshot(index)
            out(String(format: "  %-22@ микрофон %.5f  система %.5f", label as NSString,
                       level.mic, level.system))
        }
        for name in ["switch.mic.wav", "switch.sys.wav"] {
            let url = dir.appendingPathComponent(name)
            let frames = (try? AVAudioFile(forReading: url).length) ?? 0
            out(String(format: "  %@: %d кадров (%.2f с)", name, frames, Double(frames) / 16_000))
        }
        out("  главное: дорожки одной длины и системный уровень не обнулился после переключения")
    }

    /// А вот смена **входа** агрегат действительно ломает: микрофон лежит в его
    /// составе поимённо. Здесь проверяется, что пересборка случается, случается
    /// один раз и не рвёт дорожки.
    private static func probeInputSwitch() async {
        out("\n─── ступень 6: смена устройства ввода посреди записи ───")
        guard let original = CoreAudioObjects.defaultInputDevice,
              let other = alternativeInputDevice(besides: original) else {
            out("  второго устройства ввода нет — пропускаю")
            return
        }
        out("  \(CoreAudioObjects.deviceName(original)) → \(CoreAudioObjects.deviceName(other)) → обратно")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-tap-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let capture = ProcessTapCapture(
            micURL: dir.appendingPathComponent("input.mic.wav"),
            systemURL: dir.appendingPathComponent("input.sys.wav"),
            callPlatformID: nil
        )
        capture.onIssue = { out("    ⚠️  \($0)") }
        let phases = PhaseLevels()
        capture.levelCallback = { mic, system in phases.record(mic: mic, system: system) }
        do { try capture.start() } catch {
            out("  ❌ не стартовал: \(error.localizedDescription)")
            return
        }

        try? await Task.sleep(nanoseconds: 6_000_000_000)
        out("  переключаю вход…")
        phases.advance()
        guard setDefaultDevice(other, selector: kAudioHardwarePropertyDefaultInputDevice) else {
            out("  замер недействителен: вход переключить не удалось")
            _ = await capture.stop()
            return
        }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        out("  возвращаю…")
        phases.advance()
        setDefaultDevice(original, selector: kAudioHardwarePropertyDefaultInputDevice)
        try? await Task.sleep(nanoseconds: 8_000_000_000)

        let report = await capture.stop()
        setDefaultDevice(original, selector: kAudioHardwarePropertyDefaultInputDevice)

        out("  \(report.logLine)")
        for (index, label) in ["до", "на чужом входе", "после возврата"].enumerated() {
            let level = phases.snapshot(index)
            out(String(format: "  %-16@ микрофон %.5f  система %.5f", label as NSString,
                       level.mic, level.system))
        }
        for name in ["input.mic.wav", "input.sys.wav"] {
            let url = dir.appendingPathComponent(name)
            let frames = (try? AVAudioFile(forReading: url).length) ?? 0
            out(String(format: "  %@: %d кадров (%.2f с)", name, frames, Double(frames) / 16_000))
        }
        out("  ожидаем: перезапусков 2, дорожки одной длины, дыры вписаны тишиной")
    }

    private static func alternativeInputDevice(besides current: AudioDeviceID) -> AudioDeviceID? {
        CoreAudioObjects.objectList(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices
        ).first {
            $0 != current
                && CoreAudioObjects.inputChannelCount($0) > 0
                && CoreAudioObjects.deviceUID($0) != nil
        }
    }

    private static func alternativeOutputDevice(besides current: AudioDeviceID) -> AudioDeviceID? {
        CoreAudioObjects.objectList(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices
        ).first {
            $0 != current
                && CoreAudioObjects.channelCount($0, scope: kAudioObjectPropertyScopeOutput) > 0
                && CoreAudioObjects.deviceUID($0) != nil
        }
    }

    @discardableResult
    private static func setDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
        setDefaultDevice(device, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Переключает устройство по умолчанию и **проверяет, что переключилось**.
    ///
    /// Проверка не паранойя: `AudioObjectSetPropertyData` возвращает `noErr` и
    /// на те устройства, которые система делать основными отказывается (так
    /// ведут себя виртуальные карты). Замер, где переключение молча не
    /// состоялось, выглядит как «захват пережил смену устройства» — и это был
    /// бы ровно тот вывод, ради которого замер и делался, только ложный.
    @discardableResult
    private static func setDefaultDevice(
        _ device: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> Bool {
        var addr = CoreAudioObjects.address(selector)
        var value = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        )
        var readBack = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &readBack
        )
        let ok = readBack == device
        if !ok {
            out("    ⚠️  переключение не состоялось (код \(status), устройство осталось "
                + "\(CoreAudioObjects.deviceName(readBack)))")
        }
        return ok
    }

    /// Последняя ступень: не `ProcessTapCapture` напрямую, а **тот самый**
    /// `AudioRecorder`, которым пишет приложение. Между «класс работает» и
    /// «запись получается» лежит выбор пути, прогрев, сведение и длительность —
    /// и каждое из этого уже ломалось само по себе.
    @MainActor
    private static func probeThroughAudioRecorder() async {
        out("\n─── ступень 4: через AudioRecorder, 12 с ───")
        await ProcessTapCapture.warmUpIfNeeded()
        out("  путь общих часов готов: \(ProcessTapCapture.isReady)")

        let recorder = AudioRecorder()
        do {
            try recorder.start()
        } catch {
            out("  ❌ запись не началась: \(error.localizedDescription)")
            return
        }
        out("  путь: \(recorder.capturePath.rawValue)")
        try? await Task.sleep(nanoseconds: 12_000_000_000)

        do {
            let result = try await recorder.stop()
            out(String(format: "  остановлено: %.2f с, mic-only=%@",
                       result.duration, recorder.lastStopWasMicOnly ? "да" : "нет"))
            let dir = result.url.deletingLastPathComponent()
            for name in [result.url.lastPathComponent,
                         "\(result.id).mic.wav", "\(result.id).sys.wav"] {
                let url = dir.appendingPathComponent(name)
                let frames = (try? AVAudioFile(forReading: url).length) ?? 0
                out(String(format: "  %@: %d кадров (%.2f с)", name, frames, Double(frames) / 16_000))
                // Проба ничего не оставляет в архиве: запись сделана ради
                // замера, и человеку она в списке встреч не нужна.
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            out("  ❌ остановка не удалась: \(error.localizedDescription)")
        }
    }

    // MARK: - Обстановка

    private static func describeDevices() {
        out("\n─── устройства ───")
        for (label, device) in [
            ("вывод", CoreAudioObjects.defaultOutputDevice),
            ("ввод", CoreAudioObjects.defaultInputDevice),
        ] {
            guard let device else { out("  \(label): нет"); continue }
            out("  \(label): \(CoreAudioObjects.deviceName(device)) "
                + "uid=\(CoreAudioObjects.deviceUID(device) ?? "?") "
                + "входов=\(CoreAudioObjects.inputChannelCount(device)) "
                + "выходов=\(CoreAudioObjects.channelCount(device, scope: kAudioObjectPropertyScopeOutput)) "
                + "\(CoreAudioObjects.nominalSampleRate(device) ?? 0) Гц")
        }
        let outUID = CoreAudioObjects.defaultOutputDevice.flatMap { CoreAudioObjects.deviceUID($0) }
        let inUID = CoreAudioObjects.defaultInputDevice.flatMap { CoreAudioObjects.deviceUID($0) }
        if outUID == inUID {
            out("  ⚠️  ввод и вывод — одно устройство (гарнитура): в состав кладём один раз")
        }
    }

    private static func describeProcesses() {
        out("\n─── звучащие процессы ───")
        let processes = CoreAudioObjects.processList
        out("  всего: \(processes.count)")
        for object in processes {
            let bundleID = CoreAudioObjects.processBundleID(object)
            let pid = CoreAudioObjects.processPID(object)
            let name = pid.flatMap {
                NSRunningApplication(processIdentifier: $0)?.executableURL?.lastPathComponent
            }
            guard bundleID != nil || name != nil else { continue }
            out("    #\(object) pid=\(pid.map(String.init) ?? "?") \(bundleID ?? "—") \(name ?? "")")
        }
        let snapshot = MeetingDetector.captureSnapshot()
        out("  идущий звонок: \(snapshot.platformID ?? "нет")")
    }

    // MARK: - Варианты композиции

    private struct Tap {
        let id: AudioObjectID
        let uuid: UUID
        let channels: Int
    }

    private static func makeGlobalTap() -> Tap? {
        let ourselves = CoreAudioObjects.processObject(
            forPID: ProcessInfo.processInfo.processIdentifier
        )
        let description = CATapDescription(
            monoGlobalTapButExcludeProcesses: ourselves.map { [$0] } ?? []
        )
        let uuid = UUID()
        description.uuid = uuid
        description.name = "Propeller probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            out("  AudioHardwareCreateProcessTap → \(status)")
            return nil
        }
        let channels = CoreAudioObjects.tapStreamFormat(id).map { Int($0.mChannelsPerFrame) } ?? 1
        return Tap(id: id, uuid: uuid, channels: channels)
    }

    /// Сырое устройство ввода, без всякого агрегата: самый низ лестницы.
    private static func probeRawInputDevice() async {
        guard let inputDevice = CoreAudioObjects.defaultInputDevice else {
            out("\n─── ступень −1 ───\n  нет устройства ввода")
            return
        }
        let channels = CoreAudioObjects.inputChannelCount(inputDevice)
        out("\n─── ступень −1: IOProc прямо на микрофоне ───")
        out("  (первое открытие входа ждёт решения TCC — может занять минуту)")
        let listened = await listen(on: inputDevice, channels: channels, seconds: 3)
        out("  буферов \(listened.callbacks), кадров \(listened.frames), "
            + "пики \(listened.peaks.map { String(format: "%.4f", $0) }.joined(separator: " "))")
    }

    /// Агрегат из одного микрофона: контроль на то, что зависает не тап.
    private static func probeMicOnlyAggregate() async {
        out("\n─── ступень 0: агрегат только с микрофоном ───")
        guard let inputDevice = CoreAudioObjects.defaultInputDevice,
              let inputUID = CoreAudioObjects.deviceUID(inputDevice) else {
            out("  нет устройства ввода")
            return
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Propeller probe mic",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: inputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: inputUID]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = await withWatchdog("CreateAggregateDevice(mic)") {
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        }
        guard status == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
            out("  ❌ не создался: \(status.map(String.init) ?? "завис")")
            return
        }
        defer { Thread.detachNewThread { AudioHardwareDestroyAggregateDevice(aggregate) } }
        out("  создан, входных каналов \(CoreAudioObjects.inputChannelCount(aggregate))")
        let listened = await listen(
            on: aggregate, channels: CoreAudioObjects.inputChannelCount(aggregate), seconds: 3
        )
        out("  буферов \(listened.callbacks), кадров \(listened.frames), "
            + "пики \(listened.peaks.map { String(format: "%.4f", $0) }.joined(separator: " "))")
    }

    private static func probeCompositions(tap: Tap) async {
        guard let inputDevice = CoreAudioObjects.defaultInputDevice,
              let inputUID = CoreAudioObjects.deviceUID(inputDevice) else {
            out("\n❌ Нет устройства ввода — мерить нечего.")
            return
        }
        let outputDevice = CoreAudioObjects.defaultOutputDevice
        let outputUID = outputDevice.flatMap { CoreAudioObjects.deviceUID($0) }
        let micChannels = max(1, CoreAudioObjects.inputChannelCount(inputDevice))

        out("\n─── композиции ───")
        out("  ожидаем: микрофон \(micChannels) кан. + тап \(tap.channels) кан.")

        for candidate in ProcessTapCapture.compositions {
            let outputIsSeparate = candidate.includesOutputDevice
                && outputUID != nil && outputUID != inputUID
            var subDevices: [[String: Any]] = []
            var expectedBystanders = 0
            if outputIsSeparate, let outputUID, let outputDevice {
                subDevices.append([
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: candidate.mainIsOutputDevice ? 0 : 1,
                ])
                expectedBystanders = CoreAudioObjects.inputChannelCount(outputDevice)
            }
            subDevices.append([
                kAudioSubDeviceUIDKey: inputUID,
                kAudioSubDeviceDriftCompensationKey: candidate.mainIsOutputDevice ? 1 : 0,
            ])
            let mainUID = (candidate.mainIsOutputDevice && outputIsSeparate)
                ? (outputUID ?? inputUID) : inputUID

            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Propeller probe",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: mainUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: candidate.tapAutoStart,
                kAudioAggregateDeviceSubDeviceListKey: subDevices,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]

            var aggregate = AudioObjectID(kAudioObjectUnknown)
            let status = await withWatchdog("CreateAggregateDevice(\(candidate.name))") {
                AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
            }
            guard status == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
                out("\n  «\(candidate.name)» ❌ не создался: \(status.map(String.init) ?? "завис")")
                continue
            }
            defer {
                Thread.detachNewThread { AudioHardwareDestroyAggregateDevice(aggregate) }
            }

            let actual = CoreAudioObjects.inputChannelCount(aggregate)
            let expected = expectedBystanders + micChannels + tap.channels
            let rate = CoreAudioObjects.nominalSampleRate(aggregate) ?? 0
            out("\n  «\(candidate.name)» создан: входных каналов \(actual) "
                + "(ждали \(expected)), \(rate) Гц")
            out("    сабдевайсы по версии системы: "
                + CoreAudioObjects.aggregateSubDeviceUIDs(aggregate).joined(separator: ", "))
            if actual != expected {
                out("    ⚠️  раскладка не сошлась — этот вариант прод отвергнет")
            }

            let listen = await listen(on: aggregate, channels: actual, seconds: 5)
            out("    буферов за 5 с: \(listen.callbacks), кадров \(listen.frames)")
            if listen.callbacks == 0 {
                out("    ❌ IOProc не позвали ни разу — вариант мёртвый")
                continue
            }
            for (index, peak) in listen.peaks.enumerated() {
                out(String(format: "    канал %d: пик %.5f  %@", index, peak, bar(peak)))
            }
        }
    }

    private static func listen(
        on device: AudioObjectID, channels: Int, seconds: Double,
        from site: CallSite = .detachedThread
    ) async -> TapProbeListened {
        let queue = DispatchQueue(label: "app.propeller.tapprobe")
        let box = ListenBox(channels: channels)
        var procID: AudioDeviceIOProcID?
        let created = await withWatchdog("AudioDeviceCreateIOProcIDWithBlock", from: site) {
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, _, _, _ in
                box.consume(input)
            }
        }
        guard created == noErr, let procID else {
            out("    ❌ AudioDeviceCreateIOProcIDWithBlock → \(created.map(String.init) ?? "завис")")
            return TapProbeListened()
        }
        let started = await withWatchdog("AudioDeviceStart", from: site) {
            AudioDeviceStart(device, procID)
        }
        guard started == noErr else {
            out("    ❌ AudioDeviceStart → \(started.map(String.init) ?? "завис")")
            return TapProbeListened()
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        _ = await withWatchdog("AudioDeviceStop") { AudioDeviceStop(device, procID) }
        _ = await withWatchdog("AudioDeviceDestroyIOProcID") {
            AudioDeviceDestroyIOProcID(device, procID)
        }
        return box.snapshot()
    }

    private static func bar(_ peak: Float) -> String {
        String(repeating: "█", count: min(20, Int(peak * 40)))
    }

    // MARK: - Настоящий захват

    private static func probeRealCapture() async {
        out("\n─── настоящий захват, 15 с ───")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-tap-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let micURL = dir.appendingPathComponent("probe.mic.wav")
        let sysURL = dir.appendingPathComponent("probe.sys.wav")

        let platformID = MeetingDetector.captureSnapshot().platformID
        let capture = ProcessTapCapture(micURL: micURL, systemURL: sysURL, callPlatformID: platformID)
        capture.onIssue = { out("    ⚠️  \($0)") }
        out("  стартую…")
        do {
            try capture.start()
        } catch {
            out("  ❌ не стартовал: \(error.localizedDescription)")
            return
        }
        out("  пошёл, жду 15 с")
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        let report = await capture.stop()
        out("  \(report.logLine)")
        for url in [micURL, sysURL] {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .intValue ?? 0
            let frames = (try? AVAudioFile(forReading: url).length) ?? 0
            out("  \(url.lastPathComponent): \(size) байт, \(frames) кадров "
                + String(format: "(%.2f с)", Double(frames) / 16_000))
        }
        out("  стемы лежат в \(dir.path) — их и надо прогнать через tools/echo-probe")
    }
}

/// Считает пики по каждому каналу отдельно. Отдельный класс, потому что блок
/// IOProc не может писать в локальные переменные функции.

private final class ListenBox {
    private let lock = NSLock()
    private var callbacks = 0
    private var frames = 0
    private var peaks: [Float]

    init(channels: Int) {
        peaks = [Float](repeating: 0, count: max(0, channels))
    }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        var base = 0
        var counted = false
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            if !counted { frames += available; counted = true }
            let samples = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                let global = base + channel
                guard global < peaks.count else { continue }
                var peak = peaks[global]
                for frame in stride(from: 0, to: available, by: 8) {
                    peak = max(peak, abs(samples[frame * channels + channel]))
                }
                peaks[global] = peak
            }
            base += channels
        }
    }

    func snapshot() -> TapProbeListened {
        lock.lock(); defer { lock.unlock() }
        return TapProbeListened(callbacks: callbacks, frames: frames, peaks: peaks)
    }
}

struct TapProbeListened {
    var callbacks = 0
    var frames = 0
    var peaks: [Float] = []
}

/// Максимумы уровней по фазам замера. Общий максимум за всю запись ответил бы
/// «звук был», а спрашивают про другое: остался ли он после переключения.
final class PhaseLevels {
    private let lock = NSLock()
    private var phases: [(mic: Float, system: Float)] = [(0, 0)]

    func record(mic: Float, system: Float) {
        lock.lock(); defer { lock.unlock() }
        let last = phases.count - 1
        phases[last].mic = max(phases[last].mic, mic)
        phases[last].system = max(phases[last].system, system)
    }

    func advance() {
        lock.lock(); defer { lock.unlock() }
        phases.append((0, 0))
    }

    func snapshot(_ index: Int) -> (mic: Float, system: Float) {
        lock.lock(); defer { lock.unlock() }
        return index < phases.count ? phases[index] : (0, 0)
    }
}
