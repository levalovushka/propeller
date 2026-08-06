import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import PropellerPure

/// Захват встречи на общих часах: микрофон и системный звук снимаются **одним**
/// агрегатным устройством, одной IOProc, кадр в кадр.
///
/// # Что это чинит
///
/// До этого микрофон писал `AVAudioRecorder` (файл, ни буферов, ни таймстемпов),
/// а системный звук шёл через ScreenCaptureKit. Из этого следовало три вещи:
///
/// * дорожки стартовали с разницей 200–484 мс, и её приходилось измерять
///   косвенно и хранить в записи (`RecordingEntry.systemStemOffset`, дефект M2);
/// * буферы SCK дописывались подряд, а не по своим таймстемпам, отчего между
///   дорожками болталось несколько миллисекунд — когерентность в речевой полосе
///   0.04 при 0.70 у синтетики, и эхоподавитель на таком не сходится (M6);
/// * живой транскрипт был невозможен физически: микрофонных буферов не было.
///
/// Одно устройство закрывает все три: сдвига нет, потому что сэмпл номер N у
/// обеих дорожек — один и тот же момент; дрожания нет, потому что кадры кладутся
/// по `mSampleTime` часов агрегата (`CaptureCursor`); буферы есть.
///
/// # Чего это стоит
///
/// macOS 14.4 (раньше `AudioHardwareCreateProcessTap` нет — из-за этого минимум
/// приложения и поднят) и отдельное разрешение на захват звука, у которого — в
/// отличие от микрофона — **нет API, чтобы спросить статус**: отказ выглядит как
/// тишина. Поэтому путь проверяет себя фактами (пришли ли буферы, сошлось ли
/// число каналов), а не гаданием, и при неудаче честно отдаёт запись микрофону
/// одному (`CapturePathPolicy`) — второго пути захвата больше нет, он удалён
/// вместе с ScreenCaptureKit 2026-07-29.

final class ProcessTapCapture {

    // MARK: - Наружу

    struct Report {
        let compositionName: String
        let scopedToCall: Bool
        let deviceSampleRate: Double
        let framesCaptured: Int
        let paddedSilenceFrames: Int
        let droppedOverlapFrames: Int
        let reanchorCount: Int
        let ringOverflowFrames: Int
        let deviceRestarts: Int
        /// Сколько раз система сообщила о смене состава устройств. Ноль при
        /// заведомо случившейся смене означает, что слушатель не работает, —
        /// и это надо видеть в отчёте, а не выяснять по отсутствию следствий.
        let deviceNotifications: Int
        let gaveUpOnDeviceChanges: Bool
        let maxMicLevel: Float
        let maxSystemLevel: Float
        let hasSystemAudio: Bool

        /// Стем годен, если в нём есть кадры. Тишина — это тишина: собеседники
        /// могли молчать, и порогов громкости в решениях у нас нет.
        var capturedUsableStem: Bool { hasSystemAudio && framesCaptured > 0 }

        var logLine: String {
            String(
                format: """
                composition=%@ scope=%@ rate=%.0f frames=%d padded=%d dropped=%d \
                reanchors=%d ringOverflow=%d deviceNotes=%d restarts=%d gaveUp=%@ maxMic=%.5f maxSys=%.5f
                """,
                compositionName, scopedToCall ? "call" : "machine", deviceSampleRate,
                framesCaptured, paddedSilenceFrames, droppedOverlapFrames,
                reanchorCount, ringOverflowFrames, deviceNotifications, deviceRestarts,
                gaveUpOnDeviceChanges ? "yes" : "no", maxMicLevel, maxSystemLevel
            )
        }
    }

    /// Уровни для индикатора, с частотой буферов. Зовётся с очереди захвата.
    var levelCallback: ((_ mic: Float, _ system: Float) -> Void)?
    /// Готовые 16 кГц моно кадры обеих дорожек, уже выровненные. То, из чего
    /// живой слой (Э3) сделает две WebSocket-сессии; сегодня не подписан никто,
    /// и это стоит ноль.
    var onLiveFrames: ((_ mic: [Float], _ system: [Float]) -> Void)?
    /// Мягкая проблема по ходу записи — в лог, не в баннер.
    var onIssue: ((String) -> Void)?

    // MARK: - Состав агрегата

    /// Из чего собирать агрегат. Вариантов несколько не из любви к вариантам:
    /// какой из них система примет, документацией не определено, а
    /// противоречивых советов в интернете хватает. Поэтому состав — данные, а
    /// не текст в коде: пробуем сверху вниз, пока не соберётся и не поедет.
    struct Composition {
        let name: String
        /// Включать ли устройство вывода в состав.
        ///
        /// Всегда да — и это замер, а не вкус. Состав без устройства вывода
        /// (только микрофон + тап) собирается, отдаёт **правильное** число
        /// каналов и запускается, но микрофонный канал в нём мёртв: замер
        /// 2026-07-29 показал тап 0.251 и микрофон **ровно 0.000**, при том что
        /// то же устройство в одиночку давало 0.064. Отличить такой состав от
        /// здорового по числу каналов нельзя, а по тишине — нельзя тем более
        /// (собеседник имеет право молчать, и владелец тоже). Поэтому вариант
        /// не «ниже в лестнице», а удалён: молчаливо потерять владельца хуже,
        /// чем не собраться вовсе и уйти на запасной путь.
        let includesOutputDevice: Bool
        /// Кто задаёт часы. По умолчанию — микрофон: без дальней стороны запись
        /// это деградация, без владельца — брак, и терять часы должно то, что
        /// менее важно.
        let mainIsOutputDevice: Bool
        /// `kAudioAggregateDeviceTapAutoStartKey`. Обычно **выключен**: он
        /// заставляет `AudioDeviceStart` ждать, пока тапнутый процесс начнёт
        /// играть, а встречи начинаются с тишины — микрофон бы стартовал не
        /// тогда, когда человек нажал «запись», а когда собеседник заговорил.
        let tapAutoStart: Bool
    }

    static let compositions: [Composition] = [
        .init(name: "mic-clock+out", includesOutputDevice: true, mainIsOutputDevice: false, tapAutoStart: false),
        .init(name: "out-clock", includesOutputDevice: true, mainIsOutputDevice: true, tapAutoStart: false),
        .init(name: "out-clock+autostart", includesOutputDevice: true, mainIsOutputDevice: true, tapAutoStart: true),
    ]

    enum CaptureError: LocalizedError {
        case noInputDevice
        case tapCreationFailed(OSStatus)
        case noCompositionWorked(String)
        case fileCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "Нет устройства ввода — записывать нечем"
            case .tapCreationFailed(let status):
                return "Не удалось создать тап на процессы (код \(status))"
            case .noCompositionWorked(let detail):
                return "Агрегатное устройство не собралось: \(detail)"
            case .fileCreationFailed(let detail):
                return "Не удалось открыть файл стема: \(detail)"
            }
        }
    }

    // MARK: - Внутреннее

    private let micURL: URL
    private let systemURL: URL
    private let callPlatformID: String?

    private let ioQueue = DispatchQueue(label: "app.propeller.tap.io", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "app.propeller.tap.writer", qos: .utility)
    /// Состояние, к которому ходят обе очереди. Один замок на всё: конкуренция
    /// тут в наносекундах, а два замка — это порядок захвата, который однажды
    /// перепутают.
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var settleTimer: DispatchSourceTimer?

    private var composition: Composition = ProcessTapCapture.compositions[0]
    private var channelMap = CaptureChannelMap(
        micChannelOffset: 0, micChannelCount: 1,
        systemChannelOffset: 0, systemChannelCount: 0, totalChannels: 1
    )
    private var deviceSampleRate: Double = 48_000
    private var scopedToCall = false

    /// Кольцо чередующихся пар (микрофон, система) на частоте устройства.
    /// Чередование не ради экономии: так две дорожки **невыразимо** разъехаться
    /// не могут — они одна дорожка до самой записи в файлы.
    private var ring: [Float] = []
    private var ringCapacityFrames = 0
    private var ringWrite = 0
    private var ringAvailable = 0
    private var ringOverflowFrames = 0
    /// Пропуски, которые надо дописать тишиной **перед** очередным куском.
    private var pendingSegments: [(silence: Int, frames: Int)] = []

    private var cursor = CaptureCursor(sampleRate: 48_000)
    /// Разбор буфера в моно. Трогает их только очередь захвата, по одному
    /// вызову за раз.
    private var scratchMic: [Float] = []
    private var scratchSystem: [Float] = []
    private var maxMicLevel: Float = 0
    private var maxSystemLevel: Float = 0
    private var callbackCount = 0

    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var drainTimer: DispatchSourceTimer?

    private var coalescer = DeviceChangeCoalescer(boundDeviceUID: nil)
    /// UID устройства вывода, которое лежит в составе агрегата. Нужен, чтобы
    /// отличить «выбрали другой выход» (не наше дело) от «наш выход исчез».
    private var boundOutputUID: String?
    private var deviceNotifications = 0
    private var restartingSince: Date?
    private var isRunning = false
    /// Запись на паузе — кадры не берутся. Под тем же замком, что и курсор:
    /// читается на очереди захвата, ставится с главного актора.
    private var isPaused = false

    /// Что пишем на диск: 16 кГц моно — форма, которую ждёт весь конвейер.
    private static let stemSampleRate: Double = 16_000
    private static let stemFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: stemSampleRate,
        channels: 1, interleaved: false
    )!
    private static let stemFileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: stemSampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    init(micURL: URL, systemURL: URL, callPlatformID: String?) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.callPlatformID = callPlatformID
    }

    // MARK: - Прогрев

    /// Готов ли путь общих часов прямо сейчас. Читается на старте записи.
    ///
    /// # Зачем это состояние вообще есть
    ///
    /// Самое первое в жизни приложения открытие входа Core Audio ждёт решения
    /// TCC — замерено, **шестьдесят секунд**, после чего всё последующее
    /// открывается за 0.02 с. Спросить статус заранее нельзя: у разрешения на
    /// захват звука нет API, отказ выглядит как тишина.
    ///
    /// Заплатить эту минуту на старте записи означает записать встречу без
    /// первой минуты — то есть ровно то знакомство, ради которого человек
    /// нажимал кнопку. Поэтому платим её один раз при запуске приложения, в
    /// фоне, когда никто ничего не ждёт.
    private(set) static var isPathReady = false
    private static let readyLock = NSLock()

    static var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }
        return isPathReady
    }

    private static func setReady(_ value: Bool) {
        readyLock.lock()
        isPathReady = value
        readyLock.unlock()
    }

    /// Прогреть путь, если про него ещё ничего не известно.
    ///
    /// Уже подтверждённый путь не трогаем: прогрев на секунду открывает
    /// микрофон, а значит зажигает оранжевый индикатор записи. Один раз при
    /// первом запуске это честная цена за разрешение; на каждом запуске — это
    /// приложение, которое «слушает», когда его просто открыли.
    static func warmUpIfNeeded() async {
        if let known = Preferences.shared.sharedClockCaptureWorks {
            setReady(known)
            if known { return }
        }
        let ready = await warmUp()
        Preferences.shared.sharedClockCaptureWorks = ready
    }

    /// Поднять и тут же погасить захват, чтобы система приняла решение о
    /// разрешении заранее. Возвращает, годится ли путь.
    @discardableResult
    static func warmUp() async -> Bool {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-warmup", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let capture = ProcessTapCapture(
            micURL: scratch.appendingPathComponent("warmup.mic.wav"),
            systemURL: scratch.appendingPathComponent("warmup.sys.wav"),
            callPlatformID: nil
        )
        var ready = false
        do {
            try capture.start()
            ready = true
        } catch {
            debugLog("[ProcessTapCapture] прогрев не удался: \(error.localizedDescription)")
        }
        _ = await capture.stop()
        try? FileManager.default.removeItem(at: scratch)
        setReady(ready)
        debugLog("[ProcessTapCapture] прогрев: путь \(ready ? "готов" : "недоступен")")
        return ready
    }

    // MARK: - Жизненный цикл

    func start() throws {
        guard !isRunning else { return }
        try buildAndStart(isRestart: false)
        installDeviceListeners()
        isRunning = true
    }

    func stop() async -> Report {
        isRunning = false
        removeDeviceListeners()
        settleTimer?.cancel(); settleTimer = nil
        teardownAudio()

        drainTimer?.cancel(); drainTimer = nil
        // Досушиваем кольцо синхронно: файл должен быть дописан до того, как
        // вызывающий пойдёт его читать.
        await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                self?.drain(flush: true)
                self?.micFile = nil
                self?.systemFile = nil
                continuation.resume()
            }
        }
        return report()
    }

    /// Досталась ли этому захвату системная дорожка. Ответ известен после
    /// сборки агрегата: тапа могло не оказаться вовсе.
    var capturesSystemAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return channelMap.hasSystemAudio
    }

    /// Пауза: кадры перестают браться, устройство остаётся поднятым.
    ///
    /// Останавливать IOProc было бы честнее на вид и дороже по существу: на
    /// возобновлении агрегат пересобирается, а это секунда тишины и повод
    /// системе передумать про состав. Здесь же снятие паузы стоит одну
    /// перепривязку шкалы — на месте паузы дорожки просто смыкаются.
    func setPaused(_ paused: Bool) {
        lock.lock()
        guard paused != isPaused else { lock.unlock(); return }
        isPaused = paused
        if !paused {
            // Часы агрегата за время паузы ушли вперёд. Не снять шкалу с якоря —
            // значит дописать в запись всю паузу тишиной (или, если она длиннее
            // потолка `CaptureCursor`, привязаться вслепую с той же тишиной).
            cursor.detachClock()
        }
        lock.unlock()
    }

    func report() -> Report {
        lock.lock(); defer { lock.unlock() }
        return Report(
            compositionName: composition.name,
            scopedToCall: scopedToCall,
            deviceSampleRate: deviceSampleRate,
            framesCaptured: cursor.framesWritten,
            paddedSilenceFrames: cursor.paddedSilenceFrames,
            droppedOverlapFrames: cursor.droppedOverlapFrames,
            reanchorCount: cursor.reanchorCount,
            ringOverflowFrames: ringOverflowFrames,
            deviceRestarts: coalescer.restartCount,
            deviceNotifications: deviceNotifications,
            gaveUpOnDeviceChanges: coalescer.hasGivenUp,
            maxMicLevel: maxMicLevel,
            maxSystemLevel: maxSystemLevel,
            hasSystemAudio: channelMap.hasSystemAudio
        )
    }

    // MARK: - Сборка

    private func buildAndStart(isRestart: Bool) throws {
        guard let inputDevice = CoreAudioObjects.defaultInputDevice,
              let inputUID = CoreAudioObjects.deviceUID(inputDevice)
        else { throw CaptureError.noInputDevice }

        let outputDevice = CoreAudioObjects.defaultOutputDevice
        let outputUID = outputDevice.flatMap { CoreAudioObjects.deviceUID($0) }

        let (tap, tapUUID, scoped) = try makeTap()
        tapID = tap
        tapDescriptionUUID = tapUUID
        scopedToCall = scoped

        let micChannels = max(1, CoreAudioObjects.inputChannelCount(inputDevice))
        let tapChannels = CoreAudioObjects.tapStreamFormat(tap)
            .map { Int($0.mChannelsPerFrame) } ?? 1

        var failures: [String] = []
        for candidate in Self.compositions {
            do {
                try assemble(
                    candidate,
                    inputDevice: inputDevice, inputUID: inputUID,
                    outputDevice: outputDevice, outputUID: outputUID,
                    micChannels: micChannels, tapChannels: tapChannels
                )
                composition = candidate
                debugLog("[ProcessTapCapture] composition «\(candidate.name)» accepted: \(channelMap)")
                break
            } catch {
                failures.append("\(candidate.name): \(error.localizedDescription)")
                destroyAggregate()
                if candidate.name == Self.compositions.last?.name {
                    AudioHardwareDestroyProcessTap(tapID)
                    tapID = AudioObjectID(kAudioObjectUnknown)
                    throw CaptureError.noCompositionWorked(failures.joined(separator: "; "))
                }
            }
        }

        if !isRestart {
            // Курсор живёт всю запись: он и есть общая шкала. Пересборка после
            // смены устройства его не трогает — иначе всё, что уже записано,
            // потеряло бы своё место.
            cursor = CaptureCursor(sampleRate: deviceSampleRate)
            try openStems()
            startDraining()
        }
        prepareConverters()
        boundOutputUID = outputUID
        // Пересборка не создаёт коалесцер заново: он должен помнить, сколько раз
        // мы уже это делали, иначе дёргающееся устройство никогда не упрётся в
        // потолок. Подпись при этом обновляем — состав уже другой.
        if isRestart {
            coalescer.rebind(to: deviceSignature())
        } else {
            coalescer = DeviceChangeCoalescer(boundDeviceUID: deviceSignature())
        }
    }

    private func makeTap() throws -> (AudioObjectID, UUID, Bool) {
        let candidates = CoreAudioObjects.processList.map { object -> AudioProcessCandidate in
            AudioProcessCandidate(
                objectID: object,
                bundleID: CoreAudioObjects.processBundleID(object),
                executableName: CoreAudioObjects.processPID(object)
                    .flatMap { NSRunningApplication(processIdentifier: $0)?.executableURL?.lastPathComponent }
            )
        }
        let target = TapTargetPolicy.target(processes: candidates, callInProgressOn: callPlatformID)

        let description: CATapDescription
        var scoped = false
        switch target {
        case .processes(let objectIDs):
            // Моно, а не стерео: стем всё равно 16 кГц моно, и сводить два
            // канала в один нам потом самим. Пусть это делает система — вдвое
            // меньше байт через каждую границу.
            description = CATapDescription(monoMixdownOfProcesses: objectIDs.map { AudioObjectID($0) })
            scoped = true
        case .everythingExceptOurselves:
            let ourselves = CoreAudioObjects.processObject(
                forPID: ProcessInfo.processInfo.processIdentifier
            )
            description = CATapDescription(
                monoGlobalTapButExcludeProcesses: ourselves.map { [$0] } ?? []
            )
        }
        let uuid = UUID()
        description.uuid = uuid
        description.name = "Propeller"
        description.isPrivate = true
        // Обещание О2: инструмент записи не имеет права ухудшать то, что
        // записывает. `mutedWhenTapped` заглушил бы динамик у человека, который
        // просто включил запись.
        description.muteBehavior = .unmuted
        if #available(macOS 26.0, *), scoped {
            // Хелпер звонка может перезапуститься посреди встречи (у Zoom это
            // норма). До 26.0 это ловится пересборкой тапа по списку процессов;
            // здесь система возвращает процесс в тап сама, по bundle id.
            description.isProcessRestoreEnabled = true
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.tapCreationFailed(status)
        }
        return (tap, uuid, scoped)
    }

    private func assemble(
        _ candidate: Composition,
        inputDevice: AudioDeviceID, inputUID: String,
        outputDevice: AudioDeviceID?, outputUID: String?,
        micChannels: Int, tapChannels: Int
    ) throws {
        // Устройство вывода в составе обязательно — иначе микрофонный канал
        // приходит мёртвым (см. `Composition.includesOutputDevice`). Нет
        // вывода вовсе — этот путь не собирается, и работу забирает запасной.
        guard let outputUID, candidate.includesOutputDevice else {
            throw CaptureError.noCompositionWorked("нет устройства вывода")
        }
        // Одно и то же устройство (AirPods, гарнитура) нельзя класть в состав
        // дважды: каналы посчитаются вдвое, и вторая половина буфера окажется
        // мусором. Одного раза достаточно — у гарнитуры и вход, и выход свои.
        let outputIsSeparate = outputUID != inputUID

        var subDevices: [[String: Any]] = []
        var sources: [CaptureChannelSource] = []

        if outputIsSeparate, let outputDevice {
            subDevices.append([
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceDriftCompensationKey: candidate.mainIsOutputDevice ? 0 : 1,
            ])
            let outputInputs = CoreAudioObjects.inputChannelCount(outputDevice)
            if outputInputs > 0 {
                sources.append(.init(role: .bystander, channelCount: outputInputs))
            }
        }
        subDevices.append([
            kAudioSubDeviceUIDKey: inputUID,
            kAudioSubDeviceDriftCompensationKey: candidate.mainIsOutputDevice ? 1 : 0,
        ])
        sources.append(.init(role: .microphone, channelCount: micChannels))
        sources.append(.init(role: .system, channelCount: tapChannels))

        let mainUID = (candidate.mainIsOutputDevice && outputIsSeparate) ? outputUID : inputUID
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Propeller Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: candidate.tapAutoStart,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescriptionUUID?.uuidString ?? "",
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.noCompositionWorked("AudioHardwareCreateAggregateDevice \(status)")
        }
        aggregateID = aggregate

        let expected = try CaptureChannelLayout.map(sources: sources)
        let actual = CoreAudioObjects.inputChannelCount(aggregate)
        guard actual == expected.totalChannels else {
            // Каналов пришло не столько, сколько мы объявили, — значит состав
            // собрался иначе, и считать по нему смещения нельзя. Это ровно тот
            // случай, где промах молчаливый: файл пишется, в нём шум.
            throw CaptureError.noCompositionWorked(
                "каналов \(actual), ожидалось \(expected.totalChannels)"
            )
        }
        channelMap = expected
        deviceSampleRate = CoreAudioObjects.nominalSampleRate(aggregate) ?? 48_000
        allocateRing()

        try startIO()
    }

    /// UUID тапа нужен при сборке состава, а сам объект тапа его не отдаёт
    /// строкой — держим тот, что задали при создании.
    private var tapDescriptionUUID: UUID?

    private func startIO() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData: inputData, inputTime: inputTime)
        }
        guard status == noErr, let procID else {
            throw CaptureError.noCompositionWorked("AudioDeviceCreateIOProcIDWithBlock \(status)")
        }
        ioProcID = procID
        let started = AudioDeviceStart(aggregateID, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            throw CaptureError.noCompositionWorked("AudioDeviceStart \(started)")
        }

        // Состав считается рабочим только когда по нему реально пошли буферы.
        // Спрашиваем про буферы, а не про громкость: тишина в начале встречи —
        // норма, отсутствие вызовов IOProc — нет.
        let deadline = Date().addingTimeInterval(Self.firstBufferDeadline)
        while Date() < deadline {
            lock.lock(); let seen = callbackCount; lock.unlock()
            if seen > 0 { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw CaptureError.noCompositionWorked("буферы не пошли за \(Self.firstBufferDeadline) с")
    }

    /// Сколько ждать первого буфера. На разогретой системе он приходит за
    /// десятки миллисекунд; секунда — это запас, а не ожидание.
    private static let firstBufferDeadline: TimeInterval = 1.5

    // MARK: - Захват

    private func handle(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let frames = CaptureBuffers.frameCount(of: list)
        guard frames > 0 else { return }

        // На паузе кадры не берутся вовсе — ни в кольцо, ни в уровни. Курсор
        // при этом не двигается, поэтому после снятия паузы разрыв часов не
        // превратится в тишину в файле: `resume` привязывает шкалу заново.
        lock.lock()
        let paused = isPaused
        lock.unlock()
        if paused { return }

        // Буферы переиспользуются: `handle` — единственный, кто их трогает, и
        // только с очереди захвата. Аллокация сотню раз в секунду ничего бы не
        // сломала, но и делать её незачем.
        if scratchMic.count < frames {
            scratchMic = [Float](repeating: 0, count: frames)
            scratchSystem = [Float](repeating: 0, count: frames)
        }
        CaptureBuffers.mixDown(
            list, from: channelMap.micChannelOffset,
            count: channelMap.micChannelCount, frames: frames, into: &scratchMic
        )
        if channelMap.hasSystemAudio {
            CaptureBuffers.mixDown(
                list, from: channelMap.systemChannelOffset,
                count: channelMap.systemChannelCount, frames: frames, into: &scratchSystem
            )
        }

        let sampleTime = (inputTime.pointee.mFlags.contains(.sampleTimeValid))
            ? inputTime.pointee.mSampleTime : .nan

        let micPeak = CaptureBuffers.peak(scratchMic, frames: frames)
        let systemPeak = CaptureBuffers.peak(scratchSystem, frames: frames)

        lock.lock()
        callbackCount += 1
        let placement = cursor.place(sampleTime: sampleTime, frameCount: frames)
        if placement.writeFrames > 0 || placement.silenceFrames > 0 {
            appendToRing(
                mic: scratchMic, system: scratchSystem,
                skip: placement.skipFrames, write: placement.writeFrames,
                silence: placement.silenceFrames
            )
        }
        maxMicLevel = max(maxMicLevel, micPeak)
        maxSystemLevel = max(maxSystemLevel, systemPeak)
        let shouldReportLevel = callbackCount % Self.levelReportEvery == 0
        lock.unlock()

        // Буферы идут ~100 раз в секунду, а индикатору хватает десяти: остальные
        // девяносто — это чистая работа главного актора ни за чем (E5/S6).
        if shouldReportLevel { levelCallback?(micPeak, systemPeak) }
    }

    private static let levelReportEvery = 10

    /// Кладёт кадры в кольцо. Вызывается под замком.
    private func appendToRing(
        mic: [Float], system: [Float], skip: Int, write: Int, silence: Int
    ) {
        let needed = silence + write
        guard needed > 0 else { return }
        let free = ringCapacityFrames - ringAvailable
        guard free >= needed else {
            // Писатель не успевает (диск занят, машина под нагрузкой). Роняем
            // кусок и считаем его: тихо потерять кадры хуже, чем знать, сколько.
            ringOverflowFrames += needed
            return
        }
        for _ in 0..<silence {
            ring[ringWrite * 2] = 0
            ring[ringWrite * 2 + 1] = 0
            ringWrite = (ringWrite + 1) % ringCapacityFrames
        }
        for i in 0..<write {
            ring[ringWrite * 2] = mic[skip + i]
            ring[ringWrite * 2 + 1] = system[skip + i]
            ringWrite = (ringWrite + 1) % ringCapacityFrames
        }
        ringAvailable += needed
        pendingSegments.append((silence: silence, frames: write))
    }

    private func allocateRing() {
        lock.lock(); defer { lock.unlock() }
        // Восемь секунд: столько может занять пауза на переподключении
        // устройства, и столько же с запасом покрывает любой всплеск нагрузки
        // на диск. 48 кГц × 8 с × 2 дорожки × 4 байта ≈ 3 МБ.
        let capacity = Int(deviceSampleRate * 8)
        guard capacity != ringCapacityFrames else { return }
        ringCapacityFrames = capacity
        ring = [Float](repeating: 0, count: capacity * 2)
        ringWrite = 0
        ringAvailable = 0
        pendingSegments.removeAll()
    }

    /// Конвертеры создаются один раз на частоту устройства: пересоздание на
    /// каждом куске теряет состояние фильтра и щёлкает на каждой границе.
    /// После смены устройства частота может стать другой — тогда и только тогда
    /// конвертеры делаются заново.
    private func prepareConverters() {
        guard let deviceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: deviceSampleRate,
            channels: 1, interleaved: false
        ) else { return }
        if micConverter?.inputFormat.sampleRate != deviceSampleRate {
            micConverter = AVAudioConverter(from: deviceFormat, to: Self.stemFormat)
            systemConverter = AVAudioConverter(from: deviceFormat, to: Self.stemFormat)
        }
    }

    // MARK: - Запись на диск

    private func openStems() throws {
        do {
            try? FileManager.default.removeItem(at: micURL)
            micFile = try AVAudioFile(forWriting: micURL, settings: Self.stemFileSettings)
            if channelMap.hasSystemAudio {
                try? FileManager.default.removeItem(at: systemURL)
                systemFile = try AVAudioFile(forWriting: systemURL, settings: Self.stemFileSettings)
            }
        } catch {
            throw CaptureError.fileCreationFailed(error.localizedDescription)
        }
    }

    private func startDraining() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain(flush: false) }
        timer.resume()
        drainTimer = timer
    }

    private func drain(flush: Bool) {
        while true {
            lock.lock()
            guard !pendingSegments.isEmpty else { lock.unlock(); return }
            var take = 0
            var segments = 0
            // Кусками не больше полсекунды: конвертер и файл любят ровные порции,
            // а держать замок на всём кольце незачем.
            let maxFrames = Int(deviceSampleRate / 2)
            for segment in pendingSegments {
                let size = segment.silence + segment.frames
                if take > 0, take + size > maxFrames { break }
                take += size
                segments += 1
            }
            guard take > 0 else { lock.unlock(); return }
            var micChunk = [Float](repeating: 0, count: take)
            var systemChunk = [Float](repeating: 0, count: take)
            var read = (ringWrite - ringAvailable + ringCapacityFrames * 2) % ringCapacityFrames
            for i in 0..<take {
                micChunk[i] = ring[read * 2]
                systemChunk[i] = ring[read * 2 + 1]
                read = (read + 1) % ringCapacityFrames
            }
            ringAvailable -= take
            pendingSegments.removeFirst(segments)
            let hasSystem = channelMap.hasSystemAudio
            lock.unlock()

            let micOut = resample(micChunk, with: micConverter)
            let systemOut = hasSystem ? resample(systemChunk, with: systemConverter) : []
            write(micOut, to: micFile)
            if hasSystem { write(systemOut, to: systemFile) }
            if let onLiveFrames, !micOut.isEmpty {
                onLiveFrames(micOut, systemOut)
            }
            if !flush { return }
        }
    }

    private func resample(_ samples: [Float], with converter: AVAudioConverter?) -> [Float] {
        guard let converter, !samples.isEmpty else { return samples }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let ratio = Self.stemSampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.stemFormat, frameCapacity: capacity) else {
            return []
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return [] }
        let count = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
    }

    private func write(_ samples: [Float], to file: AVAudioFile?) {
        guard let file, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: Self.stemFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        do { try file.write(from: buffer) } catch {
            onIssue?("Не удалось дописать стем: \(error.localizedDescription)")
        }
    }

    // MARK: - Смена устройства (M3)

    /// Подпись состояния устройств, по изменению которой захват надо пересобрать.
    ///
    /// # Что сюда входит и почему
    ///
    /// Агрегат держит **конкретные устройства по UID** — и микрофон, и выход.
    /// Значит меняется любое из них — состав устарел:
    ///
    /// * сменился вход: микрофон лежит в составе поимённо, и после смены мы
    ///   писали бы старый (или ничего);
    /// * сменился выход: звонок теперь играет в другое устройство;
    /// * устройство из состава исчезло совсем — выдернули HDMI или USB-карту.
    ///
    /// # Что здесь **не** проверено на живой записи
    ///
    /// Пересборка после смены устройства. Проверить не на чем: на машине, где
    /// это писалось, ровно один настоящий выход и один настоящий вход, а
    /// единственная альтернатива (виртуальная карта Zoom) отказывается
    /// становиться устройством по умолчанию — `AudioObjectSetPropertyData`
    /// возвращает `noErr`, а устройство остаётся прежним.
    ///
    /// Первая версия этого места как раз и утверждала, со ссылкой на замер, что
    /// смену вывода переживать не нужно. Замер был недействителен: переключение
    /// не состоялось, и «захват выжил» означало «ничего не менялось». Проба
    /// теперь читает устройство обратно и отказывается делать вывод
    /// (`TapProbe`, ступени 5–6), а здесь выбрано осторожное поведение:
    /// пересобираться. Молча потерять дальнюю сторону до конца встречи (дефект
    /// M3) хуже, чем вписать в запись честную паузу на пересборку.
    private func deviceSignature() -> String {
        let input = CoreAudioObjects.defaultInputDevice
            .flatMap { CoreAudioObjects.deviceUID($0) } ?? "нет"
        let output = CoreAudioObjects.defaultOutputDevice
            .flatMap { CoreAudioObjects.deviceUID($0) } ?? "нет"
        let presentUIDs = Set(
            CoreAudioObjects.objectList(
                AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices
            ).compactMap { CoreAudioObjects.deviceUID($0) }
        )
        let boundAlive = boundOutputUID.map { presentUIDs.contains($0) } ?? true
        return "\(input)|\(output)|\(boundAlive ? "ok" : "исчезло")"
    }

    private func installDeviceListeners() {
        for selector in [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ] {
            var addr = CoreAudioObjects.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceMayHaveChanged()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, writerQueue, block
            )
            if status == noErr { listenerBlocks.append((addr, block)) }
        }
    }

    private func removeDeviceListeners() {
        for (addr, block) in listenerBlocks {
            var address = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, writerQueue, block
            )
        }
        listenerBlocks = []
    }

    private func deviceMayHaveChanged() {
        let signature = deviceSignature()
        lock.lock()
        deviceNotifications += 1
        let known = coalescer.currentDeviceUID
        _ = coalescer.observe(deviceUID: signature, at: Date().timeIntervalSinceReferenceDate)
        lock.unlock()
        guard signature != known else { return }
        debugLog("[ProcessTapCapture] состав устройств: \(known ?? "?") → \(signature)")
        armSettleTimer()
    }

    private func armSettleTimer() {
        guard settleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.settleDeviceChange() }
        timer.resume()
        settleTimer = timer
    }

    private func settleDeviceChange() {
        lock.lock()
        let decision = coalescer.settle(at: Date().timeIntervalSinceReferenceDate)
        lock.unlock()
        switch decision {
        case .ignore:
            return
        case .giveUp:
            settleTimer?.cancel(); settleTimer = nil
            onIssue?("Устройство вывода переключается снова и снова — оставляем запись как есть")
        case .restart:
            settleTimer?.cancel(); settleTimer = nil
            restartCapture()
        }
    }

    /// Пересобрать тап и агрегат под новое устройство.
    ///
    /// Пересоздаются **оба**: перезапуск одной IOProc или одного агрегата после
    /// смены устройства известен тем, что даёт нули вместо звука.
    private func restartCapture() {
        guard isRunning else { return }
        let outageStart = Date()
        teardownAudio()
        do {
            try buildAndStart(isRestart: true)
            lock.lock()
            cursor.reanchor()
            // Дыру вписываем честно: без неё всё сказанное после переключения
            // встало бы в записи раньше, чем было сказано.
            //
            // Но не больше, чем влезет в кольцо: курсор бы отсчитал тишину, а
            // писатель её не получил — и файл оказался бы короче того, что
            // курсор считает записанным. Пересборка дольше кольца (восемь
            // секунд) — это уже не пауза, а обрыв, и врать про неё нечем.
            let outage = Date().timeIntervalSince(outageStart)
            let roomSeconds = Double(ringCapacityFrames - ringAvailable) / deviceSampleRate
            if outage > roomSeconds {
                onIssue?(String(
                    format: "Пересборка заняла %.1f с — в запись вписано %.1f с тишины",
                    outage, roomSeconds
                ))
            }
            let padded = cursor.padGap(seconds: min(outage, roomSeconds))
            if padded > 0 {
                appendToRing(mic: [], system: [], skip: 0, write: 0, silence: padded)
            }
            lock.unlock()
            debugLog("[ProcessTapCapture] пересобрались после смены устройства")
        } catch {
            onIssue?("Не удалось пересобрать захват после смены устройства: \(error.localizedDescription)")
        }
    }

    // MARK: - Разборка

    private func teardownAudio() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func destroyAggregate() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        removeDeviceListeners()
        teardownAudio()
    }

}
