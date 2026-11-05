import Foundation

/// # Вейвформа в полосе идущей записи
///
/// Пять полосок рядом с таймером — ответ на «пишется ли вообще звук», который
/// до живого транскрипта давал сам бегущий текст. Глиф тот же, что стоит в
/// чёлке (`waveform.mid`), только он здесь движется.
///
/// **Одна вейвформа на обе стороны.** Полоска — это момент, и её высота —
/// громкость той стороны, что громче в этот момент. Мьют виден сам: микрофон
/// обнуляется до того, как с него снимут уровень (`ProcessTapCapture`), и
/// полоски остаются живыми только от собеседников.
///
/// Это прибор, а не проверка здоровья захвата: тишина здесь — просто низкие
/// полоски. Здоровье решается тем, приходили ли буферы, и никогда — громкостью
/// (инвариант захвата в `CLAUDE.md`).
public enum WaveformBars {
    /// Сколько полосок. Столько же у `waveform.mid`.
    public static let count = 5
    /// Высота тишины в долях полной: полоска не исчезает, а ложится точкой,
    /// иначе глиф в паузе между репликами пропадал бы целиком.
    public static let floor: Double = 0.14
    /// Ниже этого — тишина. Пик речи в линейной шкале — сотые доли, поэтому
    /// шкала логарифмическая: линейная показывала бы голос почти нулём.
    public static let quietDB: Double = -50

    /// Высоты полосок, 0…1, слева направо — от старого момента к новому.
    ///
    /// Берутся последние `count` моментов истории. Короткая история — в начале
    /// записи — добивается тишиной слева, а не растягивается.
    public static func heights(mic: [Float], system: [Float]) -> [Double] {
        let n = min(mic.count, system.count)
        let louder = (0..<n).map { max(mic[mic.count - n + $0], system[system.count - n + $0]) }
        let recent = Array(louder.suffix(count))
        let padded = Array(repeating: Float(0), count: count - recent.count) + recent
        return padded.map { max(floor, loudness($0)) }
    }

    /// Все полоски на полу — пауза, пустая история.
    public static var flat: [Double] { Array(repeating: floor, count: count) }

    /// Пик 0…1 в долю высоты по децибелам: `quietDB` и тише — ноль, 0 dBFS — один.
    static func loudness(_ peak: Float) -> Double {
        guard peak > 0, peak.isFinite else { return 0 }
        let db = 20 * log10(Double(min(peak, 1)))
        return max(0, min(1, (db - quietDB) / -quietDB))
    }
}
