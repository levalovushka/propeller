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
    }

    func resume(at elapsed: TimeInterval) {
        guard recordingID != nil else { return }
        openSessions(at: elapsed)
    }

    /// Запись кончилась. Текст остаётся на экране: он и есть всё, что про эту
    /// встречу известно, пока не досчитан настоящий транскрипт.
    func stop() {
        sessions.close()
    }

    /// Совсем убрать — запись сброшена, или её транскрипт уже готов.
    func end() {
        sessions.close()
        transcript = LiveTranscript()
        recordingID = nil
        attributesSpeakers = false
    }

    /// Кадры 16 кГц моно с очереди записи. Не `@MainActor`: звук не ходит через
    /// главный поток.
    nonisolated func ingest(mic: [Float], system: [Float]) {
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
        let mic = GigasttLiveSession(timeOffset: elapsed) { [weak self] event in
            Task { @MainActor in self?.absorb(event, from: .owner, of: id) }
        }
        let system = hasSystemAudio
            ? GigasttLiveSession(timeOffset: elapsed) { [weak self] event in
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
            transcript.absorb(channel: channel, start: start, end: end, text: text)
            // Длина, не текст: это лог, а встреча — не его дело.
            debugLog(
                "[Live] \(channel.rawValue) +\(text.count) знаков на \(Int(start)) с, реплик \(transcript.turns.count)"
            )
        }
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
