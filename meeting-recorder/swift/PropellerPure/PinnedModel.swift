import Foundation

/// # Модель саммари закреплена по хешу, а не по имени тега
///
/// Приложение качало `qwen3.5:4b` по имени, а имя в реестре Ollama — указатель,
/// который двигают. 2026-10 тег переставили на пересборку тех же весов: зрение
/// вынесено в отдельный проектор, параметры SSM и токенизатор пересобраны, блоб
/// весов 2,65 ГБ вместо 3,39 (сверено по заголовкам GGUF 2026-10-29: основные
/// тензоры совпадают байт в байт, 48 тензоров другой формы или типа). Ollama
/// 0.40 под тем же именем отдаёт на маке и вовсе MLX-сборку в nvfp4. Значит,
/// человек, поставивший приложение сегодня, получал не ту модель, на которой
/// мерились все саммари, и никто этого не видел.
///
/// Здесь закреплён манифест той версии, на которой мерили, **байт в байт** как
/// его записал Ollama у автора, и блобы, которые он называет. Реестр отдаёт блобы
/// по хешу (`/v2/<repo>/blobs/sha256:…`), но не манифест по хешу (404), поэтому
/// приложение тянет блобы само и само кладёт манифест туда, где его ищет Ollama.
///
/// Две вещи решены владельцем 2026-10-29:
///
/// - **Обе известные сборки считаются установленной моделью** (`acceptedModelDigests`):
///   закреплённая и та, что тег раздавал после переезда. Веса у них одни;
///   перекачивать 3,4 ГБ ради одинаковости у всех не стали. Качается при этом
///   всегда закреплённая.
/// - **Если реестр однажды перестанет отдавать закреплённые блобы** (на старый
///   манифест никто не ссылается, их могут собрать), приложение откатывается на
///   загрузку по тегу и говорит об этом в журнал и телеметрию. Без саммари вовсе —
///   это тупик (`design/no-dead-ends.md`), и он хуже другой сборки тех же весов.
///
/// Всё решаемое без сети и диска — здесь; сайдкар только читает файлы и качает.
public enum PinnedModel {

    /// Один файл из закреплённого набора.
    public struct Blob: Equatable, Sendable {
        /// `sha256:<64 hex>` — как в манифесте.
        public let digest: String
        public let size: Int64

        public init(digest: String, size: Int64) {
            self.digest = digest
            self.size = size
        }

        /// Имя файла в `models/blobs`: Ollama пишет двоеточие дефисом.
        public var fileName: String { digest.replacingOccurrences(of: ":", with: "-") }

        /// Шестнадцатеричная часть, с которой сверяется скачанное.
        public var hex: String { String(digest.dropFirst("sha256:".count)) }
    }

    /// Закрепление одной модели.
    public struct Pin: Sendable {
        /// Имя, под которым модель видят Ollama и `RecapService`.
        public let name: String
        /// `library/qwen3.5` — путь в реестре и в `manifests/registry.ollama.ai/`.
        public let repository: String
        public let tag: String
        /// Манифест как файл: эти байты кладутся на диск без пересборки.
        public let manifest: String
        /// Всё, что манифест называет: config и слои.
        public let blobs: [Blob]
        /// Хеши слоя весов, которые считаются этой моделью.
        public let acceptedModelDigests: Set<String>

        /// Путь манифеста внутри каталога моделей Ollama.
        public var manifestRelativePath: String {
            "manifests/registry.ollama.ai/\(repository)/\(tag)"
        }

        public func blobURL(_ blob: Blob) -> URL {
            URL(string: "https://registry.ollama.ai/v2/\(repository)/blobs/\(blob.digest)")!
        }
    }

    /// `qwen3.5:4b` в той сборке, на которой мерились саммари (Q4_K_M, 3,39 ГБ,
    /// манифест от 2026-07-27).
    public static let summary = Pin(
        name: "qwen3.5:4b",
        repository: "library/qwen3.5",
        tag: "4b",
        manifest: #"{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:de9fed2251b37295b763727a59ca35cf5cfe5c7379bc3e2104b2ce3c145aa887","size":475},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:81fb60c7daa80fc1123380b98970b320ae233409f0f71a72ed7b9b0d62f40490","size":3389971840},{"mediaType":"application/vnd.ollama.image.license","digest":"sha256:7339fa418c9ad3e8e12e74ad0fd26a9cc4be8703f9c110728a992b193be85cb2","size":11355},{"mediaType":"application/vnd.ollama.image.params","digest":"sha256:9371364b27a52acac9d87f88bd93c9db1174d8d6ec57f6888925cdc1788871ff","size":65}]}"#,
        blobs: [
            Blob(digest: "sha256:de9fed2251b37295b763727a59ca35cf5cfe5c7379bc3e2104b2ce3c145aa887", size: 475),
            Blob(digest: "sha256:81fb60c7daa80fc1123380b98970b320ae233409f0f71a72ed7b9b0d62f40490", size: 3_389_971_840),
            Blob(digest: "sha256:7339fa418c9ad3e8e12e74ad0fd26a9cc4be8703f9c110728a992b193be85cb2", size: 11_355),
            Blob(digest: "sha256:9371364b27a52acac9d87f88bd93c9db1174d8d6ec57f6888925cdc1788871ff", size: 65),
        ],
        acceptedModelDigests: [
            // Закреплённая сборка.
            "sha256:81fb60c7daa80fc1123380b98970b320ae233409f0f71a72ed7b9b0d62f40490",
            // Что тег раздавал с 2026-10 — те же веса, другая упаковка.
            "sha256:a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50",
        ]
    )

    /// Закрепление для имени модели, если оно есть. Модель, выбранная человеком
    /// руками, не закреплена: её качают по тегу, как раньше.
    public static func pin(for model: String) -> Pin? {
        model == summary.name ? summary : nil
    }

    /// Что лежит на диске под именем закреплённой модели.
    public enum Installed: Equatable, Sendable {
        /// Манифеста нет.
        case absent
        /// Слой весов — одна из принятых сборок, и все файлы манифеста на месте.
        case accepted
        /// Манифест есть, но слой весов чужой (тег уехал ещё раз) или файл
        /// весов не того размера. Перекачивается закреплённая сборка.
        case foreign
    }

    /// - Parameters:
    ///   - manifest: байты манифеста с диска, `nil` — файла нет.
    ///   - blobSizes: размеры файлов в `models/blobs` по имени файла
    ///     (`sha256-…`). Только нужные манифесту — остальные не важны.
    public static func installed(_ pin: Pin, manifest: Data?, blobSizes: [String: Int64]) -> Installed {
        guard let manifest else { return .absent }
        guard let layers = Self.layers(of: manifest) else { return .foreign }
        guard let model = layers.first(where: { $0.mediaType == "application/vnd.ollama.image.model" }),
              pin.acceptedModelDigests.contains(model.blob.digest) else {
            return .foreign
        }
        // Манифест без своих файлов — обрыв на полпути: Ollama его покажет, а
        // модель не загрузит. Считается чужим, чтобы недостающее докачалось.
        if layers.contains(where: { blobSizes[$0.blob.fileName] != $0.blob.size }) {
            return .foreign
        }
        return .accepted
    }

    /// Считается ли модель установленной.
    ///
    /// `fallbackTaken` — закреплённые блобы однажды не нашлись в реестре, и модель
    /// пришла по тегу. Тогда чужая сборка и есть модель: без этого каждая проверка
    /// снова объявляла бы её недоставленной, и выдача ходила бы по кругу
    /// «закреплённого нет → тег → чужая → закреплённого нет».
    public static func satisfied(_ installed: Installed, fallbackTaken: Bool) -> Bool {
        switch installed {
        case .accepted: return true
        case .foreign:  return fallbackTaken
        case .absent:   return false
        }
    }

    /// Блобы, которые после замены манифеста не нужны больше никому.
    ///
    /// Ollama 0.32.4 при старте ничего не чистит (проверено 2026-10-29: лишний блоб
    /// пережил два запуска сервера), поэтому 2,65 ГБ замещённой сборки остались бы
    /// на диске навсегда. Удаляется только то, что называл замещённый манифест, —
    /// и только если его не называет ни закреплённый, ни любой другой манифест в
    /// каталоге: модель, которую человек поставил сам, не трогается.
    ///
    /// - Parameters:
    ///   - replaced: манифест, который сейчас будет перезаписан.
    ///   - others: все остальные манифесты каталога.
    /// - Returns: имена файлов в `models/blobs`.
    public static func orphanedBlobs(_ pin: Pin, replaced: Data, others: [Data]) -> [String] {
        guard let old = layers(of: replaced) else { return [] }
        var kept = Set(pin.blobs.map(\.fileName))
        for manifest in others {
            // Нечитаемый чужой манифест: не знаем, что он держит, — не удаляем ничего.
            guard let held = layers(of: manifest) else { return [] }
            kept.formUnion(held.map(\.blob.fileName))
        }
        var seen = Set<String>()
        return old.map(\.blob.fileName).filter { !kept.contains($0) && seen.insert($0).inserted }
    }

    /// Какие файлы закреплённого набора надо скачать: которых нет или которые
    /// другого размера (обрыв прошлой попытки).
    public static func missingBlobs(_ pin: Pin, blobSizes: [String: Int64]) -> [Blob] {
        pin.blobs.filter { blobSizes[$0.fileName] != $0.size }
    }

    /// Ответ реестра на запрос блоба означает «закреплённого больше нет».
    ///
    /// Только 404 и 410: это реестр говорит о самом файле. Всё остальное — сеть,
    /// 5xx, 429 — транспорт, и откат на тег по нему подменил бы модель из-за
    /// минутной поломки.
    public static func pinGone(status: Int) -> Bool {
        status == 404 || status == 410
    }

    // MARK: - Manifest

    struct Layer {
        let mediaType: String
        let blob: Blob
    }

    /// Config и слои манифеста. `nil` — не манифест.
    static func layers(of manifest: Data) -> [Layer]? {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let config = object["config"] as? [String: Any],
              let rawLayers = object["layers"] as? [[String: Any]] else {
            return nil
        }
        var result: [Layer] = []
        for entry in [config] + rawLayers {
            guard let mediaType = entry["mediaType"] as? String,
                  let digest = entry["digest"] as? String,
                  let size = (entry["size"] as? NSNumber)?.int64Value else {
                return nil
            }
            result.append(Layer(mediaType: mediaType, blob: Blob(digest: digest, size: size)))
        }
        return result
    }
}
