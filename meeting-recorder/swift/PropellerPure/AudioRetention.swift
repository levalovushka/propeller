import Foundation

/// # Сколько живёт аудио
///
/// Аудио — самое тяжёлое, что есть у встречи, и единственное, что она умеет
/// потерять без потери смысла. Кто именно умеет — уже решено и проверено
/// (`AudioReclaim`); здесь решается только **когда**, и это правило не имеет
/// права ответить «можно» там, где то отвечает «нельзя»: иначе появилась бы
/// вторая истина о том, кому ещё нужен звук.
///
/// ## Дефолт — сразу после расшифровки
///
/// Решение владельца 2026-08-17: `afterTranscript`. Довод короткий и его нечем
/// крыть — **слушать записи приложение не даёт и не планирует**, а в то, что
/// человек пойдёт искать wav на диске и откроет его сам, верить нельзя. Значит
/// звук, переживший расшифровку, не хранится ни для чего.
///
/// Плеер (`AudioPlayer`, `WaveformScrubber`) удалён тем же решением: он висел
/// без двери и делал вид, что слушание когда-нибудь появится.
///
/// **Что этим сознательно отдано.** Переразбор архива движком получше, повторная
/// диаризация слипшегося `Speaker S1` и паралингвистика (§3.2 вижена: «голос
/// выше на треть, два перебивания») считаются из звука. После расшифровки его
/// нет — значит всё это будет доступно только встречам, записанным после того,
/// как такая работа появится, и только если человек сам выберет другой режим.
/// Доводы предъявлены и отклонены; это цена, а не недосмотр.
///
/// `keep` и `afterDays` остаются выбором в настройках — для тех, кому архив
/// звука зачем-то нужен.
public enum AudioRetentionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Аудио не удаляется само никогда. Ручная «Очистить» в настройках работает
    /// как работала.
    case keep
    /// Как только звук перестал быть входом фазы — то есть сразу после успешной
    /// расшифровки и диаризации.
    case afterTranscript
    /// Через N дней после встречи, и только если звук уже не вход.
    case afterDays

    public var id: String { rawValue }
}

public enum AudioRetention {

    /// Тридцать дней. Месяц — срок, за который к записи возвращаются: спорная
    /// формулировка в конспекте проверяется по звуку на следующей встрече серии,
    /// а серии здесь недельные и двухнедельные. Меньше — и проверять станет
    /// нечем; больше — и настройка перестаёт что-либо освобождать.
    public static let defaultDays = 30

    /// Диапазон, который настройка вообще допускает. Ноль означал бы
    /// `afterTranscript`, но сказанный другим способом, — двух путей к одному
    /// поведению не бывает.
    public static let dayRange = 1 ... 365

    public static func clampedDays(_ raw: Int) -> Int {
        min(max(raw, dayRange.lowerBound), dayRange.upperBound)
    }

    /// Встреча глазами retention: всё, что нужно решению, и ничего больше.
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let date: Date
        public let stage: RecordingStage
        public let hasTranscript: Bool
        /// Есть ли ещё что удалять. Правило не должно называть «истёкшими»
        /// встречи, у которых звука и так нет, — иначе счётчик «освободили у N
        /// встреч» врёт каждый раз.
        public let hasAudio: Bool

        public init(
            id: String, date: Date, stage: RecordingStage,
            hasTranscript: Bool, hasAudio: Bool
        ) {
            self.id = id
            self.date = date
            self.stage = stage
            self.hasTranscript = hasTranscript
            self.hasAudio = hasAudio
        }
    }

    /// У кого пора забрать звук.
    ///
    /// - Parameter now: время решения, входом — чтобы срок проверялся тестом, а
    ///   не ожиданием тридцати дней.
    public static func expired(
        _ candidates: [Candidate],
        mode: AudioRetentionMode,
        days: Int = defaultDays,
        now: Date = Date()
    ) -> [String] {
        guard mode != .keep else { return [] }
        let limit = TimeInterval(clampedDays(days)) * 86_400
        return candidates.filter { candidate in
            guard candidate.hasAudio else { return false }
            // Единственная истина о том, кому ещё нужен звук.
            guard AudioReclaim.isExpendable(
                stage: candidate.stage, hasTranscript: candidate.hasTranscript
            ) else { return false }
            switch mode {
            case .keep:
                return false
            case .afterTranscript:
                return true
            case .afterDays:
                // `>=`, а не `>`: срок «через 30 дней» истекает в момент, когда
                // прошло тридцать, а не когда пошёл тридцать первый.
                return now.timeIntervalSince(candidate.date) >= limit
            }
        }.map(\.id)
    }
}
