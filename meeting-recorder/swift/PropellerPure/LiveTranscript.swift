import Foundation

/// # Что видно, пока встреча идёт
///
/// Два потока распознавания — микрофон и системный звук — приходят по своим
/// сессиям. Экран показывает одно: реплики в том порядке, в каком они были
/// сказаны.
///
/// Здесь только эта арифметика. Она вынесена из вьюхи и из клиента, потому что
/// каждый вопрос про живую строку — «почему собеседник перебил сам себя»,
/// «почему реплика распалась на три» — это вопрос к порядку и склейке, а не к
/// сети и не к SwiftUI.
///
/// Ключевое свойство: **уже показанное не переписывается**. Движок умеет слать
/// догадки (`partial`) и решения (`final`); живой слой берёт только решения.
/// Догадка — это текст, который через полсекунды станет другим: читающему
/// разницы с решением не видно, а строка под глазами меняется. Финальный проход
/// после встречи всё равно расшифрует запись заново — живой слой не обязан быть
/// точным, он обязан не врать о том, что уже показал.
public struct LiveTranscript: Equatable, Sendable {

    /// Откуда пришла речь. Дорожек ровно две, и это не диаризация: микрофон —
    /// владелец по построению, всё остальное — дальняя сторона
    /// (`SourceAwareSpeaker`).
    public enum Channel: String, Equatable, Sendable, CaseIterable {
        case owner, remote
    }

    /// Кусок речи на общей шкале записи.
    public struct Segment: Equatable, Sendable {
        public let channel: Channel
        /// Имя говорящего из журнала окна звонилки, если машинка была уверена
        /// в момент прихода куска. Дальняя сторона только; nil — как сегодня.
        public let name: String?
        /// Секунды от начала записи (не от начала сессии — сессия может быть
        /// не первой, если запись ставили на паузу).
        public let start: Double
        public let end: Double
        public let text: String
        /// Порядок прихода. Нужен, чтобы сортировка по времени была устойчивой:
        /// два канала легко дают одинаковый `start`.
        let arrival: Int
    }

    /// Подряд идущие куски одного канала — то, что рисуется одним блоком.
    public struct Turn: Identifiable, Equatable, Sendable {
        public let id: String
        public let channel: Channel
        /// Имя из журнала окна, данное **первому** куску реплики и никогда не
        /// пересматриваемое: показанная подпись — часть показанного текста, и
        /// промис «не переписываем» распространяется на неё.
        public let name: String?
        public let startSeconds: Double
        public let timestamp: String
        /// Только растёт — печатная машинка допечатывает хвост.
        public let text: String
    }

    /// Промежуток молчания, после которого следующая фраза того же канала
    /// начинает новую реплику. Та же величина, что у готового транскрипта —
    /// иначе одна и та же встреча разбита на реплики по-разному до и после.
    public static let turnGapSeconds = TranscriptPresentation.turnGapSeconds

    private var segments: [Segment] = []
    private var arrivals = 0

    public init() {}

    public var isEmpty: Bool { segments.isEmpty }

    // MARK: - Приём

    /// Решение движка. Ложится в список навсегда.
    public mutating func absorb(
        channel: Channel, start: Double, end: Double, text: String,
        name: String? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        arrivals += 1
        let safeStart = start.isFinite && start >= 0 ? start : 0
        let safeEnd = end.isFinite ? max(end, safeStart) : safeStart
        segments.append(
            Segment(channel: channel, name: name, start: safeStart, end: safeEnd,
                    text: trimmed, arrival: arrivals)
        )
    }

    /// Новая запись — новый транскрипт.
    public mutating func reset() {
        segments.removeAll()
        arrivals = 0
    }

    // MARK: - Что рисуется

    /// Реплики в порядке произнесения.
    ///
    /// Сортировка по времени начала, а не по приходу: две сессии отвечают с
    /// разной задержкой, и «кто ответил раньше» — это про сервер, а не про
    /// встречу. При равном времени порядок прихода решает — сортировка обязана
    /// быть устойчивой, иначе строки прыгали бы местами между кадрами.
    public var turns: [Turn] {
        let all = segments.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.arrival < rhs.arrival
        }

        var turns: [Turn] = []
        var lastEnd: [Double] = []   // конец последнего куска каждой реплики

        for segment in all {
            let index = turns.count - 1
            let continues = index >= 0
                && turns[index].channel == segment.channel
                && segment.start - lastEnd[index] <= Self.turnGapSeconds
            if continues {
                let previous = turns[index]
                turns[index] = Turn(
                    id: previous.id,
                    channel: previous.channel,
                    // Имя дано первому куску; продолжение его не пересматривает,
                    // даже если журнал передумал.
                    name: previous.name,
                    startSeconds: previous.startSeconds,
                    timestamp: previous.timestamp,
                    text: Self.join(previous.text, segment.text)
                )
                lastEnd[index] = max(lastEnd[index], segment.end)
            } else {
                turns.append(
                    Turn(
                        // Имя реплики — её первый кусок: пока к реплике
                        // дописывают, она остаётся той же строкой на экране, и
                        // печатная машинка допечатывает хвост вместо того,
                        // чтобы проявлять всё заново.
                        id: "\(segment.channel.rawValue)-\(segment.arrival)",
                        channel: segment.channel,
                        name: segment.name,
                        startSeconds: segment.start,
                        timestamp: Timecode.text(segment.start),
                        text: segment.text
                    )
                )
                lastEnd.append(segment.end)
            }
        }
        return turns
    }

    /// Живой текст в том виде, в каком его хранит готовая расшифровка.
    ///
    /// # Зачем
    ///
    /// Живой текст жил только в памяти: `LiveTranscriptService.end()` обнуляет
    /// его, а на встречу не писалось ничего. Пережить остановку он мог, а
    /// перезапуск приложения — нет, и человек, закрывший ноутбук после звонка,
    /// возвращался к встрече, про которую известно ровно ничего. Час разговора
    /// при этом никуда не девался — просто до конца расшифровки его нечем было
    /// показать.
    ///
    /// # Почему тот же формат
    ///
    /// `PersistedSegment` — то, чем уже хранится расшифровка после диаризации
    /// (`mergedSegmentsJSON`). Своего формата живому тексту не заводится: тогда
    /// у экрана было бы два способа нарисовать одно и то же, и они разошлись бы
    /// — у живого слоя и у готового и так уже общая величина паузы между
    /// репликами, чтобы одна встреча не делилась на реплики по-разному до и
    /// после.
    ///
    /// Реплики, а не куски: склейка уже случилась (`turns`), и пересобирать её
    /// при чтении незачем. Поэтому `endTime` у сегмента — конец **реплики**, а
    /// точность здесь и не нужна: это черновик, который заменят.
    ///
    /// Имя говорящего проставляется здесь же и по дорожке, а не по диаризации —
    /// её на живом тексте не было и не будет. Тот же `SourceAwareSpeaker`, что
    /// поставит финальный проход, чтобы текст не переименовывал людей в момент
    /// замены.
    public func persistedSegments(ownerName: String) -> [PersistedSegment] {
        turns.enumerated().map { index, turn in
            PersistedSegment(
                index: index,
                startTime: turn.startSeconds,
                endTime: turn.startSeconds,
                text: turn.text,
                // Имя из журнала окна старше дорожечной заглушки — та же
                // лестница, что у финального прохода.
                speaker: turn.name ?? SourceAwareSpeaker.stemsOnly(
                    source: turn.channel == .owner ? .microphone : .system,
                    ownerName: ownerName
                )
            )
        }
    }

    /// Пробел между кусками — кроме случая, когда предыдущий кончился дефисом:
    /// движок так помечает оборванное слово («рабо-»), и пробел после него
    /// разорвал бы слово посреди строки.
    static func join(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if left.hasSuffix("-") { return left + right }
        return left + " " + right
    }
}
