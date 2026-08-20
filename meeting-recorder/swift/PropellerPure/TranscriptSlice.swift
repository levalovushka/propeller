import Foundation

/// # Какие куски расшифровки уезжают в разговор
///
/// Часовая встреча — это тысячи реплик. Отдать их целиком можно ровно один раз:
/// после этого в разговоре не останется места ни на что другое, в том числе на
/// ответ, ради которого расшифровку и просили. Поэтому `get_transcript` по
/// умолчанию отдаёт **фрагменты** — вокруг слов, у одного говорящего или около
/// таймкода, — а целиком только когда об этом попросили явно.
///
/// Правило вырезки живёт здесь, а не в сервере, потому что «нашлось не то место»
/// проверяется тестом на фикстуре, а не чтением ответа модели.
public enum TranscriptSlice {

    /// Сколько реплик вокруг найденной оставить, чтобы фраза не висела без
    /// разговора. Одна с каждой стороны: две уже склеивают соседние находки в
    /// сплошную стену.
    public static let contextSegments = 1
    /// Окно вокруг таймкода, в секундах.
    public static let aroundWindow: Double = 60
    /// Сколько реплик показать, когда не спросили ничего конкретного, — начало
    /// встречи.
    public static let previewCount = 12
    /// Потолок на `full`. Не выбор, а честность: у ответа есть предел, и лучше
    /// сказать, что расшифровка обрезана, чем молча отдать половину.
    public static let maxSegments = 400

    public struct Request: Equatable, Sendable {
        public let query: String
        public let speaker: String
        /// Секунда, вокруг которой нужны реплики.
        public let around: Double?
        public let full: Bool

        public init(query: String = "", speaker: String = "", around: Double? = nil, full: Bool = false) {
            self.query = query
            self.speaker = speaker
            self.around = around
            self.full = full
        }

        public var isBlank: Bool {
            query.trimmingCharacters(in: .whitespaces).isEmpty
                && speaker.trimmingCharacters(in: .whitespaces).isEmpty
                && around == nil
                && !full
        }
    }

    /// Подряд идущие реплики. Разрыв между фрагментами — это пропуск в записи, и
    /// он должен быть виден.
    public struct Fragment: Equatable, Sendable {
        public let segments: [PersistedSegment]
        public init(segments: [PersistedSegment]) { self.segments = segments }

        public var startTime: Double { segments.first?.startTime ?? 0 }
        public var endTime: Double { segments.last?.endTime ?? 0 }
    }

    public struct Slice: Equatable, Sendable {
        public let fragments: [Fragment]
        /// Правда ли, что показано не всё.
        public let truncated: Bool
        public init(fragments: [Fragment], truncated: Bool) {
            self.fragments = fragments
            self.truncated = truncated
        }

        public var isEmpty: Bool { fragments.allSatisfy { $0.segments.isEmpty } }
    }

    public static func run(segments: [PersistedSegment], request: Request) -> Slice {
        guard !segments.isEmpty else { return Slice(fragments: [], truncated: false) }

        if request.full {
            let kept = Array(segments.prefix(maxSegments))
            return Slice(fragments: [Fragment(segments: kept)], truncated: kept.count < segments.count)
        }
        if request.isBlank {
            let kept = Array(segments.prefix(previewCount))
            return Slice(fragments: [Fragment(segments: kept)], truncated: kept.count < segments.count)
        }

        let query = ArchiveSearch.fold(request.query.trimmingCharacters(in: .whitespaces))
        let speaker = ArchiveSearch.fold(request.speaker.trimmingCharacters(in: .whitespaces))

        // Каждое условие — сито, и они складываются: «что говорил Костя про
        // вебхуки» — это speaker и query сразу, а не два разных запроса.
        var picked: [Int] = []
        for (index, segment) in segments.enumerated() {
            if !speaker.isEmpty {
                let name = ArchiveSearch.fold(segment.speaker)
                guard name.contains(speaker) || speaker.contains(name) else { continue }
            }
            if !query.isEmpty {
                guard ArchiveSearch.fold(segment.text).contains(query) else { continue }
            }
            if let around = request.around {
                guard segment.endTime >= around - aroundWindow,
                      segment.startTime <= around + aroundWindow else { continue }
            }
            picked.append(index)
        }
        guard !picked.isEmpty else { return Slice(fragments: [], truncated: false) }

        // Контекст добавляется только к поиску по словам: у говорящего и у окна
        // вокруг таймкода отбор сам по себе связный, и соседняя реплика там —
        // это чужая реплика, которую не просили.
        let context = query.isEmpty ? 0 : contextSegments
        var wanted = Set<Int>()
        for index in picked {
            for offset in -context...context {
                let neighbour = index + offset
                if segments.indices.contains(neighbour) { wanted.insert(neighbour) }
            }
        }

        let ordered = wanted.sorted()
        let capped = Array(ordered.prefix(maxSegments))
        var fragments: [Fragment] = []
        var run: [PersistedSegment] = []
        var previous: Int?
        for index in capped {
            if let previous, index != previous + 1, !run.isEmpty {
                fragments.append(Fragment(segments: run))
                run = []
            }
            run.append(segments[index])
            previous = index
        }
        if !run.isEmpty { fragments.append(Fragment(segments: run)) }
        return Slice(fragments: fragments, truncated: capped.count < ordered.count)
    }

    // MARK: - В текст

    public static func stamp(_ seconds: Double) -> String {
        Timecode.text(seconds)
    }

    /// Фрагменты словами. Пропуск между ними назван, а не проглочен: иначе две
    /// далёкие реплики читаются как один разговор.
    public static func render(_ slice: Slice) -> String {
        var lines: [String] = []
        for (index, fragment) in slice.fragments.enumerated() where !fragment.segments.isEmpty {
            if index > 0 { lines.append("…") }
            for segment in fragment.segments {
                lines.append("[\(stamp(segment.startTime))] \(segment.speaker): \(segment.text)")
            }
        }
        if slice.truncated { lines.append("… расшифровка показана не целиком") }
        return lines.joined(separator: "\n")
    }
}
