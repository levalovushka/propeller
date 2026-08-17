import Foundation

/// # Сколько живёт аудио
///
/// Аудио — самое тяжёлое, что есть у встречи, и единственное, что она умеет
/// потерять без потери смысла. Кто именно умеет — уже решено и проверено
/// (`AudioReclaim`); здесь решается только **когда**, и это правило не имеет
/// права ответить «можно» там, где то отвечает «нельзя»: иначе появилась бы
/// вторая истина о том, кому ещё нужен звук.
///
/// ## Дефолт — тридцать дней
///
/// Решение владельца 2026-08-17: `afterDays` с `defaultDays` включён по
/// умолчанию. Опасение, из-за которого дефолтом сначала поставили `keep`
/// («апдейт пройдёт по архиву, который человек уже накопил»), проверено и
/// оказалось беспредметным: приложение вышло в публичный доступ 10 августа,
/// а в самом старом архиве — владельца — на 17 августа не было ни одного файла
/// старше тридцати дней (162 wav, самый ранний от 27 июля). Удалять при
/// обновлении нечего, поэтому никакого водораздела и одноразовой миграции у
/// правила нет: лишний механизм под задачу, которой не существует.
///
/// Что теряется в худшем случае — звук встречи месячной давности у раннего
/// тестировщика. Расшифровка и конспект остаются: аудио — единственное, что
/// встреча умеет потерять без потери смысла.
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
