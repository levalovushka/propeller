import Foundation

/// Где в одном входном буфере лежит микрофон, а где — системный звук.
///
/// # Почему это вообще вопрос
///
/// Захват на общих часах — это одно агрегатное устройство, внутри которого
/// сабдевайсы (микрофон, устройство вывода) и тап на процессы встречи. Одна
/// IOProc отдаёт **все** входные каналы агрегата одним буфером: сколько бы
/// источников в нём ни было, кадр номер N у всех — один и тот же момент
/// времени. Ради этого всё и затевалось.
///
/// Цена — надо знать, какой канал чей. Порядок каналов агрегата = порядок
/// сабдевайсов в композиции, а за ними тапы в своём порядке. Композицию строим
/// мы сами, значит порядок известен по построению; неизвестны только
/// **количества** каналов, и их система сообщает.
///
/// # Почему нельзя просто «канал 0 — микрофон, канал 1 — система»
///
/// Три случая ломают наивную раскладку, и все три встречаются у живых людей:
///
/// 1. **AirPods**: устройство ввода и вывода — одно и то же. Положить его в
///    композицию дважды нельзя, и микрофонных каналов там может быть один.
/// 2. **Внешняя карта / USB-гарнитура**: устройство вывода само имеет входы,
///    и они займут каналы перед микрофоном.
/// 3. **Стерео-микрофон**: два канала вместо одного, и системный звук уезжает.
///
/// Поэтому раскладка считается из фактических длин, а не угадывается.
public struct CaptureChannelMap: Equatable {

    /// Первый канал микрофона во входном буфере агрегата.
    public let micChannelOffset: Int
    public let micChannelCount: Int
    /// Первый канал системного звука (тапа).
    public let systemChannelOffset: Int
    public let systemChannelCount: Int
    /// Сколько всего входных каналов должно прийти. Если пришло другое —
    /// раскладка не та, и лучше это заметить сразу, чем писать шум.
    public let totalChannels: Int

    public init(
        micChannelOffset: Int,
        micChannelCount: Int,
        systemChannelOffset: Int,
        systemChannelCount: Int,
        totalChannels: Int
    ) {
        self.micChannelOffset = micChannelOffset
        self.micChannelCount = micChannelCount
        self.systemChannelOffset = systemChannelOffset
        self.systemChannelCount = systemChannelCount
        self.totalChannels = totalChannels
    }

    /// Есть ли в этой раскладке дальняя сторона. Микрофон обязателен всегда,
    /// системный звук — нет: запись без него это mic-only, а не отказ.
    public var hasSystemAudio: Bool { systemChannelCount > 0 }
}

/// Один источник входных каналов внутри агрегата, в том порядке, в каком он
/// объявлен в композиции.
public struct CaptureChannelSource: Equatable {

    public enum Role: Equatable {
        /// Микрофон владельца.
        case microphone
        /// Тап: то, что слышно из динамиков.
        case system
        /// Входы, которые нам не нужны, но каналы занимают: линейные входы
        /// внешней карты, вход HDMI-монитора, вход гарнитуры, которую мы взяли
        /// ради часов вывода.
        case bystander
    }

    public let role: Role
    public let channelCount: Int

    public init(role: Role, channelCount: Int) {
        self.role = role
        self.channelCount = channelCount
    }
}

public enum CaptureChannelLayoutError: Error, Equatable {
    /// Микрофона в агрегате нет. Записывать нечего — это отказ, а не деградация.
    case noMicrophoneChannels
    /// Источник объявлен, но каналов у него ноль или меньше.
    case emptySource(CaptureChannelSource.Role)
    /// Микрофон объявлен дважды: значит композицию собрали с дублем устройства
    /// (классически — AirPods, попавшие и как вход, и как выход).
    case duplicateRole(CaptureChannelSource.Role)
}

public enum CaptureChannelLayout {

    /// Раскладка каналов по объявленной композиции.
    ///
    /// - Parameter sources: источники **в том же порядке**, в каком они лежат
    ///   в композиции агрегата: сначала сабдевайсы, потом тапы.
    public static func map(sources: [CaptureChannelSource]) throws -> CaptureChannelMap {
        var seen = Set<String>()
        for source in sources {
            guard source.channelCount > 0 else { throw CaptureChannelLayoutError.emptySource(source.role) }
            if source.role == .bystander { continue }
            guard seen.insert(String(describing: source.role)).inserted else {
                throw CaptureChannelLayoutError.duplicateRole(source.role)
            }
        }

        var offset = 0
        var mic: (offset: Int, count: Int)?
        var system: (offset: Int, count: Int)?
        for source in sources {
            switch source.role {
            case .microphone: mic = (offset, source.channelCount)
            case .system: system = (offset, source.channelCount)
            case .bystander: break
            }
            offset += source.channelCount
        }

        guard let mic else { throw CaptureChannelLayoutError.noMicrophoneChannels }

        return CaptureChannelMap(
            micChannelOffset: mic.offset,
            micChannelCount: mic.count,
            systemChannelOffset: system?.offset ?? 0,
            systemChannelCount: system?.count ?? 0,
            totalChannels: offset
        )
    }
}
