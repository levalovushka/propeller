import Foundation

/// # Что остаётся на диске от прошлого набора весов распознавания
///
/// Веса едут внутри `.app` (247 МБ) и клонируются в
/// `Application Support/Meeting Recorder/gigastt-models` при первом запуске
/// (`GigasttSidecar.seedModelsFromBundle`) — писать рядом с ними нельзя, каталог
/// подписан. Копирование пропускает файлы, которые уже на месте, и никогда ничего не
/// удаляет: смени сборка имя энкодера — и старый файл на 225 МБ остаётся у человека
/// навсегда, потому что искать его некому.
///
/// Правило удаляет **только веса** — файлы `.onnx`, которых нет в наборе из бандла.
/// Всё остальное в каталоге принадлежит не нам: `coreml_cache/` компилирует и читает
/// сам gigastt, lock-файлы он же, а `presenceMarker` — наш нулевой файл, которым
/// затыкается его проверка наличия FP32-энкодера. Узость здесь важнее полноты: у
/// каталога один хозяин, и он не мы.
///
/// **Пустой набор из бандла означает «ничего не удалять».** Сборка из `swift build`
/// не имеет Resources, и там ответ «в бандле весов нет» — это отсутствие знания, а не
/// знание об отсутствии. Прочитать его вторым способом значит вычистить веса у
/// разработчика, а на машине человека — при любой поломке чтения бандла.
public enum ASRModelSweep {

    /// Имя FP32-энкодера, которое gigastt проверяет на существование, но никогда не
    /// открывает (`GigasttSidecar.ensureEncoderPresenceMarker`). Ноль байт, наш файл.
    public static let presenceMarker = "v3_e2e_rnnt_encoder.onnx"

    /// Файл из бандла: имя и размер. Размер — потому что имя не отвечает на вопрос
    /// «те ли это байты»: набор может поехать, не поменяв ни одного имени.
    public struct BundledFile: Equatable, Sendable {
        public var name: String
        public var size: Int64

        public init(name: String, size: Int64) {
            self.name = name
            self.size = size
        }
    }

    /// Какие файлы надо положить из бандла: которых нет или которые другого размера.
    ///
    /// **Почему размер, а не только имя.** Копирование пропускало всё, что уже на
    /// месте, а имена у набора стабильные — `v3_e2e_rnnt_encoder_int8.onnx` тот же
    /// в каждой сборке. Значит сборка, которая поменяла **байты** весов, не меняя
    /// имён, не доехала бы ни до одной существующей установки: файл на месте,
    /// вопросов нет, у человека навсегда остаются прошлые веса. Так же выглядел бы
    /// и обрыв первого копирования — половина файла на диске и никто её не переложит.
    ///
    /// Размер, а не хеш, потому что это 225 МБ на каждом запуске против пяти
    /// обращений к метаданным. Разные веса одного размера до байта — случай, за
    /// который здесь не платят; за ним стоит менять имя.
    ///
    /// Пустой бандл, как и в `stalePaths`, означает «ничего не делать».
    public static func outdatedPaths(
        bundled: [BundledFile],
        installed: [String: Int64]
    ) -> [String] {
        guard !bundled.isEmpty else { return [] }
        return bundled.filter { file in
            guard let have = installed[file.name] else { return true }
            return have != file.size
        }.map(\.name).sorted()
    }

    /// Веса, оставшиеся от предыдущего набора.
    ///
    /// - Parameters:
    ///   - existing: имена в каталоге весов сейчас.
    ///   - bundled: имена, которые несёт текущий бандл.
    public static func stalePaths(existing: [String], bundled: Set<String>) -> [String] {
        guard !bundled.isEmpty else { return [] }
        return existing.filter { name in
            guard name.hasSuffix(".onnx") else { return false }
            guard name != presenceMarker else { return false }
            return !bundled.contains(name)
        }.sorted()
    }
}
