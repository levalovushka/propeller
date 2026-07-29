import AudioToolbox
import Foundation

/// Как достать одну дорожку из входного буфера агрегата.
///
/// # Почему это здесь, а не рядом с захватом
///
/// Потому что ошибиться здесь — значит записать чужую речь в микрофонную
/// дорожку, и узнать об этом, когда кто-то сядет слушать встречу. Раскладка
/// буферов у агрегата не одна: он **обычно** кладёт каждый источник отдельным
/// `AudioBuffer` с одним каналом, но встречается и один буфер с чередующимися
/// каналами, и промежуточные варианты (внешняя карта отдаёт свои входы вместе).
/// Все три разбираются одним проходом по сквозной нумерации каналов — и это
/// ровно то, что должно проверяться тестом, а не живой встречей.
public enum CaptureBuffers {

    /// Сколько кадров в этом наборе буферов.
    ///
    /// Считается по первому буферу: у всех буферов одного вызова IOProc кадров
    /// поровну — это и значит «общие часы».
    public static func frameCount(of list: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = list.first, first.mNumberChannels > 0 else { return 0 }
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
    }

    /// Сколько всего каналов во всех буферах.
    public static func channelCount(of list: UnsafeMutableAudioBufferListPointer) -> Int {
        list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Сводит `count` каналов, начиная со сквозного номера `from`, в моно.
    ///
    /// Возвращает, сколько каналов действительно нашлось. Ноль означает, что
    /// раскладка не та, — и это надо заметить, а не записать тишину.
    @discardableResult
    public static func mixDown(
        _ list: UnsafeMutableAudioBufferListPointer,
        from: Int,
        count: Int,
        frames: Int,
        into destination: inout [Float]
    ) -> Int {
        guard count > 0, frames > 0, destination.count >= frames else { return 0 }
        for index in 0..<frames { destination[index] = 0 }

        var base = 0
        var mixed = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                let global = base + channel
                guard global >= from, global < from + count else { continue }
                for frame in 0..<min(frames, available) {
                    destination[frame] += samples[frame * channels + channel]
                }
                mixed += 1
            }
            base += channels
        }

        // Среднее, а не сумма: стерео-микрофон иначе стал бы вдвое громче
        // моно, и автоматический гейн в миксе принялся бы это «чинить».
        if mixed > 1 {
            let scale = 1 / Float(mixed)
            for index in 0..<frames { destination[index] *= scale }
        }
        return mixed
    }

    /// Пик по прореженной выборке. Для индикатора и для отчёта — точность здесь
    /// не нужна, а сто вызовов в секунду по полному буферу нужны ещё меньше.
    public static func peak(_ samples: [Float], frames: Int? = nil) -> Float {
        let count = min(frames ?? samples.count, samples.count)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        let step = max(1, count / 128)
        for index in stride(from: 0, to: count, by: step) {
            peak = max(peak, abs(samples[index]))
        }
        return min(1, peak)
    }
}
