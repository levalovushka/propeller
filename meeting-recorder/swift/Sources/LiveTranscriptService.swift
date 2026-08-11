import Foundation
import PropellerPure

/// # Живой слой встречи
///
/// Две сессии распознавания на две дорожки одного захвата (`ProcessTapCapture`
/// отдаёт их кадр в кадр), и один транскрипт, который из них складывается
/// (`LiveTranscript`). Всё, что решается — решено там; здесь остаются провода:
/// когда сессии открыть, куда девать кадры, что делать на паузе.
///
/// **Живой слой ничего не должен встрече.** Нет сайдкара, нет сети, нет
/// доступа — на экране просто не появляется текст, и это не состояние отказа:
/// запись идёт, файл пишется, настоящий транскрипт будет сделан после
/// остановки (`design/no-dead-ends.md`). Поэтому отсюда наружу не выходит ни
/// одного сообщения об ошибке.
@MainActor
final class LiveTranscriptService: ObservableObject {

    /// Что показано прямо сейчас.
    @Published private(set) var transcript = LiveTranscript()
    /// Чья это встреча — id записи, к которой относится текст. Нужен, чтобы
    /// текст ушедшей встречи не показался поверх следующей.
    @Published private(set) var recordingID: String?
    /// Можно ли по этому тексту сказать, кто говорил.
    ///
    /// Ровно тогда, когда дорожек две: разделение людей здесь и есть разница
    /// между дорожками, а не диаризация. Один канал слышит всех сразу, и
    /// подписать его владельцем — значит отдать ему каждую чужую реплику.
    @Published private(set) var attributesSpeakers = false

    /// Сессии живут вне главного актора: кадры приходят с очереди записи.
    private let sessions = LiveSessionPair()
    /// Громкость обеих дорожек по окнам. Пишется с очереди записи, читается с
    /// главного актора — отсюда замок.
    private let loudness = LoudnessLog()
    /// Реплика владельца, уже сказанная дальней стороной, — это эхо из колонки.
    /// Решение принимается по тексту: сравнение громкостей на этот вопрос
    /// отвечать не может (`EchoDedup`).
    private var dedup = EchoDedup()
    /// Была ли системная дорожка у этого захвата. На микрофонном пути её нет,
    /// и вторую сессию открывать не за чем.
    private var hasSystemAudio = false

    // MARK: - Жизненный цикл

    /// Начать живой слой для записи `id`. Сайдкар поднимается здесь же — во
    /// время встречи он нужен впервые, а `ensureReady` заодно снимает
    /// отложенную остановку по простою.
    func begin(recordingID id: String, hasSystemAudio: Bool, elapsed: TimeInterval) {
        end()
        transcript = LiveTranscript()
        recordingID = id
        self.hasSystemAudio = hasSystemAudio
        attributesSpeakers = hasSystemAudio
        openSessions(at: elapsed)
    }

    /// Пауза: сессии закрываются, сказанное остаётся. Держать сокет открытым на
    /// паузе незачем — сервер закроет его сам по простою, а возобновление всё
    /// равно начинает новый отсчёт времени. Хвост короче порции уходит движку
    /// при закрытии, так что последние слова перед паузой не пропадают.
    func pause() {
        sessions.close()
        // Ждать ответа дальней стороны больше нечего: её сессия закрыта.
        show(dedup.flush())
    }

    func resume(at elapsed: TimeInterval) {
        guard recordingID != nil else { return }
        openSessions(at: elapsed)
    }

    /// Запись кончилась. Текст остаётся на экране: он и есть всё, что про эту
    /// встречу известно, пока не досчитан настоящий транскрипт.
    func stop() {
        sessions.close()
        show(dedup.flush())
    }

    /// Совсем убрать — запись сброшена, или её транскрипт уже готов.
    func end() {
        sessions.close()
        transcript = LiveTranscript()
        recordingID = nil
        attributesSpeakers = false
        // Счётчик кадров — часы записи: у следующей встречи они свои.
        loudness.reset()
        dedup.reset()
    }

    /// Кадры 16 кГц моно с очереди записи. Не `@MainActor`: звук не ходит через
    /// главный поток.
    nonisolated func ingest(mic: [Float], system: [Float]) {
        loudness.note(mic: mic, system: system)
        sessions.feed(mic: mic, system: system)
    }

#if GALLERY
    /// Живой текст без встречи, микрофона и сайдкара — для снимка состояния.
    /// Сессии при этом не открываются: галерея не имеет права ничего слушать.
    func galleryPose(recordingID id: String, transcript posed: LiveTranscript) {
        sessions.close()
        recordingID = id
        transcript = posed
        // Позе неоткуда взять признак: у неё нет захвата. Но он выводится из
        // самого текста — две дорожки в нём и есть то, из чего берутся имена.
        attributesSpeakers = Set(posed.turns.map(\.channel)).count > 1
    }
#endif

    // MARK: - Сессии

    private func openSessions(at elapsed: TimeInterval) {
        let id = recordingID
        // Гейт читает ту же громкость, что и правило атрибуции, и по ней не
        // отдаёт движку порции, в которых уверенно говорит дальняя сторона:
        // микрофон слышит её из колонки, эти слова распознаются целиком и потом
        // выбрасываются в `absorb`. Замерено: −26 % работы сайдкара, WER не хуже,
        // атрибуция та же (`benchmarks/report-gate.md`).
        let loudness = self.loudness
        let gate = FeedGate(rules: .echo)
        let windows: (TimeInterval, TimeInterval) -> [FeedGate.Window] = { from, to in
            loudness.windows(from: from, to: to)
        }

        let mic = GigasttLiveSession(
            timeOffset: elapsed, channel: .owner, gate: gate, windowsInRange: windows
        ) { [weak self] event in
            Task { @MainActor in self?.absorb(event, from: .owner, of: id) }
        }
        let system = hasSystemAudio
            ? GigasttLiveSession(
                timeOffset: elapsed, channel: .remote, gate: gate, windowsInRange: windows
              ) { [weak self] event in
                Task { @MainActor in self?.absorb(event, from: .remote, of: id) }
              }
            : nil
        sessions.open(mic: mic, system: system)

        // Сайдкар может быть ещё не поднят — сессии подождут его на своей
        // лестнице пауз, а кадры до готовности лежат в их же буфере.
        Task {
            do {
                try await GigasttSidecar.shared.ensureReady()
            } catch {
                debugLog("[Live] сайдкар не поднялся (\(error.localizedDescription)) — живого текста не будет")
            }
        }
    }

    private func absorb(_ event: GigasttLiveSession.Event, from channel: LiveTranscript.Channel, of id: String?) {
        // Событие опоздавшей сессии предыдущей встречи не имеет права попасть
        // в текущую.
        guard id == recordingID else { return }
        switch event {
        case .ready:
            debugLog("[Live] сессия \(channel.rawValue) слушает")
        case .text(let text, let start, let end):
            // Микрофонная сессия слышит владельца — и, если человек на колонках,
            // дальнюю сторону тоже: 95–97 % её слов распознаётся из одного
            // микрофона (`ECHO_AND_MIX_EXPERIMENTS.md` §1). Тогда её речь
            // приезжает сюда под именем владельца. Отсекает это `EchoDedup`: то,
            // что дальняя сторона уже сказала, владелец сказать не мог.
            switch channel {
            case .remote:
                transcript.absorb(channel: .remote, start: start, end: end, text: text)
                debugLog(
                    "[Live] remote +\(text.count) знаков на \(Int(start)) с, реплик \(transcript.turns.count)"
                )
                show(dedup.remoteSaid(start: start, end: end, text: text))
            case .owner:
                // «Звучал ли системный стем», а не «кто громче»: собственный
                // голос владельца в его же микрофоне тише эха на 4–6 dB
                // (замер 2026-08-11), и сравнивать уровни бессмысленно.
                let audible = loudness.farSideAudible(from: start, to: end)
                let admitted = dedup.ownerSaid(
                    start: start, end: end, text: text,
                    farSideAudible: audible, at: ProcessInfo.processInfo.systemUptime
                )
                if admitted.isEmpty {
                    debugLog(
                        "[Live] владелец на \(Int(start)) с: \(text.count) знаков "
                        + (dedup.waitingCount > 0 ? "ждут дальнюю сторону" : "— эхо, не показываю")
                    )
                    scheduleDedupTick()
                }
                show(admitted)
            }
        }
    }

    /// Показать то, что дедуп выпустил. Пустой список — обычное дело: реплика
    /// либо ещё ждёт, либо оказалась эхом.
    private func show(_ lines: [EchoDedup.Line]) {
        for line in lines {
            transcript.absorb(channel: .owner, start: line.start, end: line.end, text: line.text)
            debugLog(
                "[Live] owner +\(line.text.count) знаков на \(Int(line.start)) с, реплик \(transcript.turns.count)"
            )
        }
    }

    /// Реплика ждёт ответа дальней стороны — а он может и не прийти (она молчит,
    /// её сессия переподключается). Тогда через `holdSeconds` реплика
    /// показывается: отсутствие замера не есть замер. Таймер одноразовый и
    /// заводится только когда есть кого ждать — «ничего не должны ⇒ никаких
    /// таймеров».
    private func scheduleDedupTick() {
        guard dedup.waitingCount > 0 else { return }
        let id = recordingID
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(EchoDedup.holdSeconds * 1_000_000_000) + 100_000_000)
            guard let self, self.recordingID == id else { return }
            self.show(self.dedup.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }
}

/// Громкость обеих дорожек по кадрам, за замком.
///
/// Часы здесь — сами кадры: 16 кГц, и счётчик прошедших кадров и есть секунды
/// записи, то есть та же шкала, на которой движок отдаёт времена реплик. Пауза
/// останавливает захват, значит останавливает и этот счётчик — ровно как таймер
/// встречи.
private final class LoudnessLog: @unchecked Sendable {
    private let lock = NSLock()
    /// Окна громкости обеих дорожек. Их спрашивают двое — гейт (нужен срез по
    /// отрезку порции) и дедуп (звучала ли дальняя сторона на отрезке реплики), —
    /// и оба про одно и то же, поэтому список один.
    private var gateWindows: [FeedGate.Window] = []
    /// Что в микрофоне не объясняется дальней стороной. Считается здесь же, из
    /// тех же кадров: два места, считающих по одному звуку, разошлись бы.
    private var coherence = EchoCoherence()
    private var framesSeen = 0

    private static let sampleRate = 16_000.0
    /// Живая реплика приезжает через пару секунд, минуты хватает с запасом, а
    /// встреча на восемь часов не имеет права расти в памяти.
    private static let historySeconds = 60.0

    func note(mic: [Float], system: [Float]) {
        guard !mic.isEmpty else { return }
        // Системной дорожки может не быть вовсе (микрофонный путь) — тогда
        // объяснять эхо нечем, и `EchoCoherence` честно отвечает «замера нет»:
        // гейт в этом случае отдаёт порцию.
        let micLevel = Self.rms(mic)
        let systemLevel = Self.rms(system)
        lock.lock()
        let cells = coherence.note(mic: mic, system: system)
        let start = Double(framesSeen) / Self.sampleRate
        framesSeen += mic.count
        let end = Double(framesSeen) / Self.sampleRate
        gateWindows.append(
            FeedGate.Window(
                start: start, end: end, mic: micLevel, system: systemLevel, cells: cells
            )
        )
        let cutoff = end - Self.historySeconds
        if let first = gateWindows.first, first.end < cutoff {
            gateWindows.removeAll { $0.end < cutoff }
        }
        lock.unlock()
    }

    /// Окна, попадающие на отрезок встречи. Пустой ответ значит «замера нет», и
    /// гейт в этом случае порцию отдаёт: отсутствие замера не есть замер.
    func windows(from: Double, to: Double) -> [FeedGate.Window] {
        lock.lock(); defer { lock.unlock() }
        return gateWindows.filter { $0.end > from && $0.start < to }
    }

    /// Звучал ли системный стем на этом отрезке — то есть могло ли эхо дальней
    /// стороны попасть в микрофон.
    ///
    /// Сравнения дорожек здесь нет намеренно: замер 2026-08-11 показал, что
    /// собственный голос владельца в его микрофоне тише эха на 4–6 dB, и любое
    /// сравнение уровней отвечает на этот вопрос неверно. Спрашивается только
    /// цифровая тишина, а она от усиления не зависит.
    ///
    /// Замера нет — `false`: отсутствие замера не есть замер, и реплика
    /// показывается без задержки.
    func farSideAudible(from start: Double, to end: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gateWindows.contains {
            $0.end > start && $0.start < end && $0.system >= FeedGate.silenceFloor
        }
    }

    func reset() {
        lock.lock()
        gateWindows.removeAll(keepingCapacity: true)
        coherence.reset()
        framesSeen = 0
        lock.unlock()
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Две сессии за одним замком.
///
/// Существует ради одного: кадры приходят с очереди записи, а открывают и
/// закрывают сессии с главного актора. Держать это в `@MainActor`-классе значит
/// гонять звук через главный поток двадцать раз в секунду.
private final class LiveSessionPair: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: GigasttLiveSession?
    private var system: GigasttLiveSession?

    func open(mic: GigasttLiveSession, system: GigasttLiveSession?) {
        lock.lock()
        let old = (self.mic, self.system)
        self.mic = mic
        self.system = system
        lock.unlock()
        old.0?.close()
        old.1?.close()
        mic.start()
        system?.start()
    }

    func feed(mic frames: [Float], system systemFrames: [Float]) {
        lock.lock()
        let micSession = mic
        let systemSession = system
        lock.unlock()
        micSession?.feed(frames)
        systemSession?.feed(systemFrames)
    }

    func close() {
        lock.lock()
        let old = (mic, system)
        mic = nil
        system = nil
        lock.unlock()
        old.0?.close()
        old.1?.close()
    }
}
