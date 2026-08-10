import Foundation
import PropellerPure

/// # Одна живая сессия распознавания
///
/// Сокет к `ws://127.0.0.1:9876/v1/ws`: конфигурация, поток 16 кГц моно
/// **кусками по две секунды**, обратно — решения движка. Одна дорожка = одна
/// сессия, потому что так получается атрибуция: то, что пришло из микрофонной
/// сессии, сказал владелец.
///
/// # Почему две секунды, а не «как приходит»
///
/// Потому что замерено. Движок распознаёт то, что успело прийти, и куском по
/// 200 мс (как отдаёт захват) он режет речь на огрызки: 1.8 слова на сегмент и
/// **25 % WER** против офлайнового прохода по тому же звуку. Ровно тот же звук
/// кусками по 2 с — 2.8 слова на сегмент и **9.7 %**; на второй записи 33.6 %
/// против 19.1 %. Дальше не лучше: 2.5 с дают 12.5 %, 3 с — 13.9 %, то есть
/// оптимум именно здесь, а не «чем больше, тем лучше».
///
/// VAD на это не влияет вовсе (те же 9.7 % при 2 с и хуже при 200 мс), поэтому
/// его нет: он стоил бы ещё одной модели в бандле.
///
/// Плата — задержка: слова появляются через ~2 с после того, как сказаны.
/// Это сознательный обмен, живая строка нужна читаемой, а не быстрой.
///
/// **Ничего не обещает.** Живой текст — приятная добавка к встрече, а не её
/// содержание: настоящий транскрипт делает проход по файлу после остановки.
/// Поэтому здесь нет ни одной ветки, которая доходит до человека: сокет упал —
/// сессия молча поднимается заново, сервер ответил ошибкой — то же самое.
/// Единственное, чего делать нельзя, — тратить батарею на бесконечный
/// коннект-шторм, отсюда лестница пауз.
///
/// Живёт вне главного актора: кадры приходят с очереди записи ~20 раз в
/// секунду, и звук не должен ходить через главный поток. Наружу отдаются
/// только события, и уже там вызывающий решает, куда с ними идти.
final class GigasttLiveSession: @unchecked Sendable {

    enum Event {
        /// Сервер принял конфигурацию — с этого момента он слушает.
        case ready
        /// Решение движка. Догадки (`partial`) сюда не доходят вовсе: текст,
        /// который через полсекунды станет другим, читающему не отличить от
        /// решённого, а строка под глазами меняется.
        case text(String, start: Double, end: Double)
    }

    /// Секунды записи, прошедшие к первому кадру этой сессии. Времена слов
    /// приходят от начала сессии, а показывать их надо от начала встречи.
    private let timeOffset: TimeInterval
    private let onEvent: (Event) -> Void

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    /// Кадры, ещё не отданные движку: копятся до `chunkFrames`, а пока сокет не
    /// готов — просто копятся. Не безразмерно: висящий коннект не должен
    /// превращаться в растущий буфер.
    private var buffer: [Float] = []
    private var isReady = false
    private var isClosed = false
    private var attempt = 0
    private var reconnectWork: DispatchWorkItem?
    /// Сколько кадров прошло через эту дорожку с начала сессии — отданных и нет.
    /// Часы встречи: 16 кГц, поэтому счётчик кадров и есть секунды.
    private var framesSeen = 0
    /// Перевод шкалы движка в шкалу встречи.
    ///
    /// Существует ради двух разных вещей, у которых оказалась одна арифметика.
    /// **Обрыв:** времена слов движок считает от начала своего сокета, и сокет,
    /// поднятый заново на сороковой минуте, снова начинает с нуля — без перевода
    /// весь текст после обрыва лёг бы в начало встречи. **Гейт:** порция, которую
    /// мы решили не отдавать, для движка не существует, и с этого момента его
    /// шкала отстаёт от встречи ровно на её длину.
    ///
    /// Раньше первое решалось парой счётчиков (`framesStreamed` +
    /// `connectionBaseFrames`), но со вторым это стало бы двумя смещениями
    /// одновременно — то есть двумя ответами на вопрос «когда это было сказано».
    private var timeline = FedTimeline()
    /// Конец последней отданной порции в шкале встречи — для keepalive: сокет
    /// закрывается сам, если кадров не было пять минут.
    private var lastFedMeetingEnd: TimeInterval = 0

    /// Чья это дорожка. Гейт спрашивает у микрофонной и системной разное: в
    /// системном стеме владельца быть не может, а в микрофонном может быть
    /// дальняя сторона из колонки.
    private let channel: LiveTranscript.Channel
    /// Правило, по которому порция может не уйти движку. `nil` — отдавать всё.
    private let gate: FeedGate?
    /// Громкость обеих дорожек на отрезке встречи. Считается один раз на кадр
    /// в `LiveTranscriptService`, здесь только спрашивается.
    private let windowsInRange: ((TimeInterval, TimeInterval) -> [FeedGate.Window])?

    private static let sampleRate = 16_000
    /// Порция, которой кормим движок. Две секунды — замер, а не вкус (см. выше).
    private static let chunkFrames = 2 * sampleRate
    /// Сколько звука имеет смысл придержать, пока сокет не поднялся. Десять
    /// секунд: столько ждёт лестница пауз на переподключении, а дальше проще
    /// потерять кусок встречи, чем копить его в памяти.
    private static let bufferLimitFrames = 10 * sampleRate

    init(
        timeOffset: TimeInterval,
        channel: LiveTranscript.Channel = .owner,
        gate: FeedGate? = nil,
        windowsInRange: ((TimeInterval, TimeInterval) -> [FeedGate.Window])? = nil,
        onEvent: @escaping (Event) -> Void
    ) {
        self.timeOffset = timeOffset
        self.channel = channel
        self.gate = gate
        self.windowsInRange = windowsInRange
        self.onEvent = onEvent
    }

    // MARK: - Жизнь сокета

    func start() {
        lock.lock()
        guard !isClosed, task == nil else { lock.unlock(); return }
        lock.unlock()
        connect()
    }

    private func connect() {
        let configuration = URLSessionConfiguration.ephemeral
        // Сокет живёт всю встречу; запрос не «долгий», он постоянный.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = Self.longestMeeting
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: Self.endpoint)
        socket.maximumMessageSize = 4 * 1024 * 1024

        lock.lock()
        guard !isClosed else { lock.unlock(); session.invalidateAndCancel(); return }
        self.session = session
        self.task = socket
        self.isReady = false
        lock.unlock()

        socket.resume()
        receive(on: socket)
        // Конфигурация обязана уйти до первого кадра — сервер отвечает
        // `configure_too_late`, если наоборот.
        send(text: #"{"type":"configure","sample_rate":16000}"#, on: socket)
    }

    /// Закрыть навсегда: пауза, остановка записи, конец приложения.
    ///
    /// Хвост короче порции уходит движку, и сокету дают договорить: последние
    /// сказанные слова — те самые, ради которых на строку и смотрят.
    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let socket = task
        let session = self.session
        let ready = isReady
        let tail = buffer
        isReady = false
        task = nil
        self.session = nil
        buffer.removeAll()
        reconnectWork?.cancel()
        reconnectWork = nil
        lock.unlock()

        guard let socket else {
            session?.invalidateAndCancel()
            return
        }
        if ready, !tail.isEmpty {
            send(data: Self.pcm16(tail), on: socket)
            // Не мгновенное закрытие: ответ на хвост идёт своим чередом, и
            // оборвать сокет в ту же секунду значит выбросить его.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.closingGrace) {
                socket.cancel(with: .goingAway, reason: nil)
                session?.invalidateAndCancel()
            }
            return
        }
        socket.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Сколько ждать последнего ответа после закрытия. Замер: решение приходит
    /// через ~0.2 с после звука, секунда — с запасом.
    private static let closingGrace: TimeInterval = 1.0

    // MARK: - Звук

    /// Кадры 16 кГц моно с очереди записи. Уходят движку порциями по две
    /// секунды — этим порция и набирается.
    func feed(_ frames: [Float]) {
        guard !frames.isEmpty else { return }
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        framesSeen += frames.count
        buffer.append(contentsOf: frames)
        if buffer.count > Self.bufferLimitFrames {
            let excess = buffer.count - Self.bufferLimitFrames
            buffer.removeFirst(excess)
            // Выброшенное всё равно прошло по шкале встречи: иначе после
            // долгого обрыва весь дальнейший текст лёг бы раньше, чем был
            // сказан.
            timeline.skipped(seconds: Double(excess) / Double(Self.sampleRate))
        }
        guard isReady, let socket = task, buffer.count >= Self.chunkFrames else {
            lock.unlock()
            return
        }
        let portion = buffer
        buffer.removeAll(keepingCapacity: true)

        let seconds = Double(portion.count) / Double(Self.sampleRate)
        // Начало порции на шкале встречи — по кадрам, а не по стенным часам:
        // кадры и есть время записи, и на паузе они не идут.
        let meetingStart = timeOffset
            + Double(framesSeen - portion.count) / Double(Self.sampleRate)

        if let gate {
            let windows = windowsInRange?(meetingStart, meetingStart + seconds) ?? []
            guard gate.shouldSend(
                channel: channel,
                windows: windows,
                secondsSinceLastSend: meetingStart - lastFedMeetingEnd
            ) else {
                timeline.skipped(seconds: seconds)
                lock.unlock()
                return
            }
        }

        timeline.fed(meetingStart: meetingStart, seconds: seconds)
        lastFedMeetingEnd = meetingStart + seconds
        lock.unlock()
        send(data: Self.pcm16(portion), on: socket)
    }

    /// Отдать остаток, не дожидаясь полной порции: сокет поднялся, запись
    /// встала на паузу или кончилась. Хвост короче двух секунд движок всё равно
    /// распознает — хуже, чем целую порцию, но лучше, чем никак.
    private func flushBuffer(on socket: URLSessionWebSocketTask) {
        lock.lock()
        let held = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !held.isEmpty else { lock.unlock(); return }
        // Хвост уходит независимо от гейта: это конец записи или пауза, а
        // последние сказанные слова — те самые, ради которых на строку смотрят.
        let seconds = Double(held.count) / Double(Self.sampleRate)
        let meetingStart = timeOffset
            + Double(framesSeen - held.count) / Double(Self.sampleRate)
        timeline.fed(meetingStart: meetingStart, seconds: seconds)
        lastFedMeetingEnd = meetingStart + seconds
        lock.unlock()
        send(data: Self.pcm16(held), on: socket)
    }

    /// Float −1…1 → little-endian Int16, как ждёт движок.
    private static func pcm16(_ frames: [Float]) -> Data {
        var samples = [Int16](repeating: 0, count: frames.count)
        for i in 0..<frames.count {
            let clamped = min(max(frames[i], -1), 1)
            samples[i] = Int16(clamped * 32767)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func send(text: String, on socket: URLSessionWebSocketTask) {
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            self?.fail(socket, because: "send configure: \(error.localizedDescription)")
        }
    }

    private func send(data: Data, on socket: URLSessionWebSocketTask) {
        socket.send(.data(data)) { [weak self] error in
            guard let error else { return }
            self?.fail(socket, because: "send audio: \(error.localizedDescription)")
        }
    }

    // MARK: - Ответы

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(socket, because: "receive: \(error.localizedDescription)")
            case .success(let message):
                if case .string(let text) = message { self.handle(text, on: socket) }
                self.receive(on: socket)
            }
        }
    }

    private func handle(_ json: String, on socket: URLSessionWebSocketTask) {
        guard let data = json.data(using: .utf8),
              let message = try? JSONDecoder().decode(ServerMessage.self, from: data)
        else { return }

        switch message.type {
        case "ready":
            lock.lock()
            let mine = task === socket
            if mine {
                isReady = true
                attempt = 0
                // Новый сокет — новая шкала: движок снова считает с нуля, и
                // прежние отметки к его временам больше не относятся.
                timeline = FedTimeline()
            }
            lock.unlock()
            guard mine else { return }
            // Копившееся, пока сокет поднимался, уходит сразу — иначе первая
            // порция ждала бы ещё две секунды поверх коннекта.
            flushBuffer(on: socket)
            onEvent(.ready)
        case "final":
            guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            let span = message.span()
            lock.lock()
            let start = timeline.meetingTime(forServer: span.start)
            let end = timeline.meetingTime(forServer: span.end)
            lock.unlock()
            onEvent(.text(text, start: start, end: max(end, start)))
        case "partial":
            // Догадка. Живому слою она не нужна: см. заголовок файла.
            break
        case "error":
            // Сессию с ошибкой не чинят разговором — её поднимают заново.
            fail(socket, because: "server: \(message.code ?? message.message ?? "error")")
        default:
            break
        }
    }

    /// Сокет умер. Молча поднимаем следующий — с задержкой, чтобы упавший
    /// сервер не встретил шторм переподключений.
    private func fail(_ socket: URLSessionWebSocketTask, because reason: String) {
        lock.lock()
        guard !isClosed, task === socket else { lock.unlock(); return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isReady = false
        attempt += 1
        let delay = Self.backoff(attempt)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork?.cancel()
        reconnectWork = work
        lock.unlock()

        socket.cancel(with: .abnormalClosure, reason: nil)
        debugLog("[LiveSession] сессия оборвалась (\(reason)) — новая через \(Int(delay)) с")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func backoff(_ attempt: Int) -> TimeInterval {
        switch attempt {
        case ..<2: return 1
        case 2: return 3
        case 3: return 8
        default: return 20
        }
    }

    private static let endpoint = URL(
        string: "ws://127.0.0.1:\(GigasttSidecar.port)/v1/ws"
    )!

    /// Потолок записи (`AppState.maxRecordingSeconds`), повторённый здесь
    /// числом: он нужен вне главного актора, а ходить туда за константой —
    /// значит ждать главный поток на очереди захвата.
    private static let longestMeeting: TimeInterval = 8 * 3600

    // MARK: - Разбор

    private struct ServerMessage: Decodable {
        let type: String
        let text: String?
        let words: [Word]?
        let code: String?
        let message: String?

        struct Word: Decodable {
            let start: Double?
            let end: Double?
        }

        /// Куда этот кусок попадает на шкале **движка**. Перевод во время
        /// встречи — дело `FedTimeline`: только он знает, сколько звука до этого
        /// момента не было отдано.
        func span() -> (start: Double, end: Double) {
            let starts = words?.compactMap(\.start) ?? []
            let ends = words?.compactMap(\.end) ?? []
            let start = starts.min() ?? 0
            let end = ends.max() ?? start
            return (start, max(end, start))
        }
    }
}
