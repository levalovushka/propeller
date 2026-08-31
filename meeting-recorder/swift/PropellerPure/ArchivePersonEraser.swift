import Foundation

/// Чем кончилось «стереть человека». Ответ на вопрос «точно ли нигде не
/// осталось» — не обещание, а перечисление файлов, где имя ещё есть.
public struct PersonErasureReport: Equatable, Sendable {
    /// Строк индекса, в которых что-то изменилось.
    public var entriesChanged: Int
    /// Файлы, которые перезаписаны или переименованы.
    public var filesChanged: [String]
    /// Файлы, в которых имя осталось. Пусто — стёрто везде.
    public var remaining: [String]

    public init(entriesChanged: Int = 0, filesChanged: [String] = [], remaining: [String] = []) {
        self.entriesChanged = entriesChanged
        self.filesChanged = filesChanged.sorted()
        self.remaining = remaining.sorted()
    }

    public var isComplete: Bool { remaining.isEmpty }
}

/// Виды мест, где в архиве лежит имя человека.
///
/// Перечисление, а не два списка путей. До 2026-08-31 места были захардкожены
/// дважды — в `erase` и в `remaining`, — и списки разошлись: трассы окна
/// звонилки (`<id>.calltrace.jsonl`) не было ни в одном. Замер на живом архиве:
/// по одному человеку стиралось 3 348 вхождений и оставалось **54 388** в
/// восьми трассах, а `isComplete` при этом говорил «стёрто везде», потому что
/// `remaining` смотрел в те же неполные места. Необратимая операция приватности
/// обещала полноту и не давала её.
///
/// Так же устроено стирание встречи (`MeetingTrace`): обход по `allCases` с
/// исчерпывающим `switch`. Новый вид следа не соберётся, пока про него не
/// сказали, где он лежит и в какой он форме, — и тогда же он попадёт **и** в
/// стирание, **и** в проверку. Разойтись им теперь негде: у них один обход.
public enum PersonTrace: String, CaseIterable, Sendable {
    /// `meetings/*.md` — расшифровки и конспекты. Имя лежит и в тексте, и в
    /// имени файла: slug собран из заголовка и кириллицу не выбрасывает.
    case meetingDocuments
    /// `recordings.json` и все его снимки (`.bak`, карантинные `corrupt-*`).
    /// Записи одной формы, и человек в них один и тот же.
    case indexEntries
    /// `recordings/<id>.calltrace.jsonl` — трасса окна звонилки
    /// (`MeetingTrace.callWindowTrace`). Единственное место, где имена лежат
    /// буквально и массово: 52 МБ трасс против 4,9 МБ всей папки `meetings/`.
    /// Плюс `AppState.backfillCallRosters` читает трассу и восстанавливает из
    /// неё состав встречи — стёртое имя вернулось бы в индекс само.
    case callWindowTraces
    /// `projects.json`. Имя проекта — обычный текст: «1×1 с Даней» обязан
    /// пережить стирание Дани в виде «1×1 с Участник», иначе человек остался в
    /// архиве под вывеской.
    case projectDefinitions
    /// `projects-silenced.json` — связки, на которые сказали «нет». Ключ вида
    /// `title:1x1 с даней` несёт имя ровно так же, как несёт его заголовок.
    case silencedProjects
    /// `deleted.json`. Имени в надгробии быть не может — там id и дата, оба
    /// структурные, — но проверка обязана смотреть и сюда: «не может» про файл,
    /// который никто не читал, это догадка, а не ответ.
    case tombstones
}

extension PersonTrace {

    /// В какой форме лежит след. От формы зависит только способ чистки.
    enum Form {
        /// Текст плюс имя файла.
        case markdownDocument
        /// Массив объектов; изменённые записи считаются в отчёт.
        case indexArray
        /// JSONL: по объекту на строку.
        case jsonLines
        /// Массив свёрнутых ключей (`ArchiveSearch.fold`): замена сворачивается
        /// вместе с ними, иначе ключ перестанет совпадать с пересчитанным.
        case foldedKeys
    }

    /// Хвост имени файла трассы. Тот же, по которому её опознаёт
    /// `MeetingErasure.kind` как `MeetingTrace.callWindowTrace`.
    static let callTraceSuffix = ".calltrace.jsonl"

    /// Файлы этого вида, лежащие в архиве сейчас. Файла может не быть — чистка
    /// и проверка обе переживают отсутствие молча.
    func places(in layout: ArchiveLayout) -> [URL] {
        switch self {
        case .meetingDocuments:
            return ArchiveEraser.filenames(in: layout.meetings)
                .filter { $0.hasSuffix(".md") }
                .map { layout.meetings.appendingPathComponent($0) }
        case .indexEntries:
            return ArchiveEraser.filenames(in: layout.recordings)
                .filter { $0 == ArchiveLayout.indexName || ArchiveLayout.isIndexSnapshot($0) }
                .map { layout.recordings.appendingPathComponent($0) }
        case .callWindowTraces:
            return ArchiveEraser.filenames(in: layout.recordings)
                .filter { $0.hasSuffix(Self.callTraceSuffix) }
                .map { layout.recordings.appendingPathComponent($0) }
        case .projectDefinitions:
            return [layout.projectsURL]
        case .silencedProjects:
            return [layout.silencedProjectsURL]
        case .tombstones:
            return [layout.tombstonesURL]
        }
    }

    var form: Form {
        switch self {
        case .meetingDocuments: return .markdownDocument
        case .indexEntries, .projectDefinitions, .tombstones: return .indexArray
        case .callWindowTraces: return .jsonLines
        case .silencedProjects: return .foldedKeys
        }
    }
}

/// Сквозняк по всему архиву: документы встреч, живой индекс и все его копии,
/// трассы окна звонилки, проекты, заглушенные связки, надгробия.
///
/// Один проход, а не «по встрече за раз», потому что человек не принадлежит
/// встрече: он в двадцати, и в снимке индекса, снятом до половины из них.
public enum ArchivePersonEraser {

    @discardableResult
    public static func erase(
        person raw: String,
        in layout: ArchiveLayout,
        with replacement: String = PersonErasure.defaultReplacement
    ) -> PersonErasureReport {
        let name = PersonName(raw)
        guard !name.isEmpty else { return PersonErasureReport() }

        var changed: [String] = []
        var entriesChanged = 0

        // Обход по видам следов, а не по списку путей: тот же обход, которым
        // потом отвечает `remaining`.
        for trace in PersonTrace.allCases {
            for url in trace.places(in: layout) {
                let filename = url.lastPathComponent
                switch trace.form {
                case .markdownDocument:
                    if redactDocument(filename, in: url.deletingLastPathComponent(),
                                      name: name, with: replacement) {
                        changed.append(filename)
                    }
                case .indexArray:
                    let touched = redactIndex(at: url, name: name, with: replacement)
                    if touched > 0 {
                        entriesChanged += touched
                        changed.append(filename)
                    }
                case .jsonLines:
                    if redactJSONLines(at: url, name: name, with: replacement) {
                        changed.append(filename)
                    }
                case .foldedKeys:
                    // Ключ связки — свёрнутый заголовок (`ArchiveSearch.fold`),
                    // и пересчитан он будет из уже стёртого заголовка. Замена
                    // сворачивается вместе с ключом, иначе «больше не
                    // предлагать» перестало бы совпадать и связка всплыла бы
                    // снова — под нейтральным именем, но всплыла.
                    if redactJSONValue(at: url, name: name,
                                       with: ArchiveSearch.fold(replacement)) {
                        changed.append(filename)
                    }
                }
            }
        }

        return PersonErasureReport(
            entriesChanged: entriesChanged,
            filesChanged: changed,
            remaining: remaining(person: raw, in: layout)
        )
    }

    /// Файлы архива, в которых имя ещё встречается. Тем же обходом и тем же
    /// поиском, которыми стирали.
    public static func remaining(person raw: String, in layout: ArchiveLayout) -> [String] {
        let name = PersonName(raw)
        guard !name.isEmpty else { return [] }
        var left: [String] = []

        for trace in PersonTrace.allCases {
            for url in trace.places(in: layout) {
                let filename = url.lastPathComponent
                // Сырым текстом намеренно: файлы архива пишутся в UTF-8 без
                // экранирования, а вложенный JSON (`mergedSegmentsJSON`) в
                // индексе — строка, где имя лежит как есть. Разбор структуры
                // тут ответил бы про поля, которые мы знаем, а спросить надо
                // про файл целиком.
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if PersonErasure.contains(filename, name: name)
                    || PersonErasure.contains(text, name: name) {
                    left.append(filename)
                }
            }
        }
        return left
    }

    // MARK: - Документ

    private static func redactDocument(
        _ filename: String, in dir: URL, name: PersonName, with replacement: String
    ) -> Bool {
        let fm = FileManager.default
        let url = dir.appendingPathComponent(filename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }

        var touched = false
        let cleaned = PersonErasure.redacted(text, name: name, with: replacement)
        if cleaned != text {
            guard (try? cleaned.write(to: url, atomically: true, encoding: .utf8)) != nil else {
                return false
            }
            touched = true
        }

        let newName = PersonErasure.redactedFilename(filename, name: name, with: replacement)
        if newName != filename {
            let target = dir.appendingPathComponent(newName)
            // Занятое имя не повод перетереть чужой файл. Документ остаётся под
            // прежним именем и попадёт в `remaining` — это честнее, чем потеря.
            if !fm.fileExists(atPath: target.path), (try? fm.moveItem(at: url, to: target)) != nil {
                touched = true
            }
        }
        return touched
    }

    // MARK: - Индекс

    /// Сколько записей изменилось.
    private static func redactIndex(at url: URL, name: PersonName, with replacement: String) -> Int {
        guard let entries = IndexFile.entries(at: url) else { return 0 }
        var out: [[String: Any]] = []
        var changed = 0
        for entry in entries {
            let cleaned = PersonErasure.redactedJSON(entry, name: name, with: replacement)
            guard let dict = cleaned as? [String: Any] else {
                out.append(entry)
                continue
            }
            if !NSDictionary(dictionary: dict).isEqual(to: entry) { changed += 1 }
            out.append(dict)
        }
        guard changed > 0 else { return 0 }
        return IndexFile.write(out, to: url) ? changed : 0
    }

    /// Совпадают ли два разобранных JSON-значения. `NSDictionary.isEqual(to:)`
    /// умеет только словари, а сюда прилетает и массив, и голая строка.
    private static func sameJSON(_ a: Any, _ b: Any) -> Bool {
        guard let lhs = a as? NSObject, let rhs = b as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }

    // MARK: - Любой JSON

    /// Файл, который целиком один JSON произвольной формы — массив строк,
    /// объект, что угодно. `IndexFile` тут не годится: он требует массив
    /// объектов и на `["title:1x1 с даней"]` отвечает «не разобралось».
    private static func redactJSONValue(
        at url: URL, name: PersonName, with replacement: String
    ) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]
              )
        else { return false }
        let cleaned = PersonErasure.redactedJSON(value, name: name, with: replacement)
        guard !sameJSON(cleaned, value) else { return false }
        guard let out = try? JSONSerialization.data(
            withJSONObject: cleaned, options: [.fragmentsAllowed]
        ) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    // MARK: - Трасса окна звонилки

    /// Трасса — JSONL: заголовок `meta`, дальше по опросу на строку, в каждом
    /// плитки, и в плитке `description` вида `"Имя, звук, видео"`.
    ///
    /// **Имя подменяется, плитка не удаляется.** Удалить плитку значит изменить
    /// состав опроса, а состав — это вход правил `CallWindowJournal.verdict`:
    /// геометрия требует минимум двух названных плиток, метка Zoom считает
    /// помеченные. Убрав одну, мы получили бы другой вердикт **про других
    /// людей** — молчание там, где был говорящий, или чужое имя вместо
    /// `twoLabels`. Подмена оставляет и число плиток, и площади, и хвост
    /// состояния нетронутыми: журнал считает ровно то же, что считал, только
    /// под нейтральной подписью — как метка спикера в расшифровке становится
    /// `[Участник]`, а не пустотой. И `backfillCallRosters`, дочитывающий состав
    /// из трассы, вернёт в индекс «Участник», а не стёртое имя.
    ///
    /// Разбор построчный и терпимый: строка, которая не разбирается (оборванный
    /// хвост убитого процесса — `CallWindowJournal.polls` такую пропускает),
    /// чистится сырым текстом. Соврать «имени нет» про нечитаемую строку нельзя.
    ///
    /// Цена сказана вслух: пересборка строки печатает дробные числа полными
    /// семнадцатью знаками — `"t":0.9` становится `"t":0.90000000000000002`,
    /// и файл толстеет на процент. Значение при этом **то же самое** до бита
    /// (проверено сравнением всех `t` на живой трассе 2026-08-31), а якорь
    /// `anchorUnix` и так печатался полностью. Чистить сырым текстом было бы
    /// компактнее и опаснее: имя, совпавшее с ключом JSON, переименовало бы
    /// поле, и опрос потерялся бы целиком. Разбор трогает только значения.
    private static func redactJSONLines(
        at url: URL, name: PersonName, with replacement: String
    ) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard PersonErasure.contains(text, name: name) else { return false }

        var out = String()
        out.reserveCapacity(text.count)
        var touched = false
        // `omittingEmptySubsequences: false` — пустые строки и хвостовой перевод
        // строки обязаны пережить чистку байт в байт: трасса это запись, а не
        // документ, и её длина в строках сравнивается с числом опросов.
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false
        )
        for (i, line) in lines.enumerated() {
            if i > 0 { out.append("\n") }
            let raw = String(line)
            if raw.isEmpty { continue }
            if let value = try? JSONSerialization.jsonObject(
                with: Data(raw.utf8), options: [.fragmentsAllowed]
            ) {
                let cleaned = PersonErasure.redactedJSON(value, name: name, with: replacement)
                if !sameJSON(cleaned, value),
                   let encoded = try? JSONSerialization.data(
                       withJSONObject: cleaned, options: [.fragmentsAllowed]
                   ) {
                    out += String(decoding: encoded, as: UTF8.self)
                    touched = true
                    continue
                }
                out += raw
                continue
            }
            // Не разобралось — значит структуры нет, а имя может быть.
            let cleaned = PersonErasure.redacted(raw, name: name, with: replacement)
            if cleaned != raw { touched = true }
            out += cleaned
        }

        guard touched else { return false }
        return (try? Data(out.utf8).write(to: url, options: .atomic)) != nil
    }
}
