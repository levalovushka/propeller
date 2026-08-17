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

/// Сквозняк по всему архиву: `meetings/*.md`, живой индекс и все его копии.
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

        // 1. Документы встреч: расшифровки и конспекты. Правится и текст, и имя
        //    файла — slug собран из заголовка.
        for filename in ArchiveEraser.filenames(in: layout.meetings) where filename.hasSuffix(".md") {
            if redactDocument(filename, in: layout.meetings, name: name, with: replacement) {
                changed.append(filename)
            }
        }

        // 2. Живой индекс и все снимки — одним правилом: и там и там лежат
        //    записи одной формы, и человек в них один и тот же.
        for filename in ArchiveEraser.filenames(in: layout.recordings)
        where filename == ArchiveLayout.indexName || ArchiveLayout.isIndexSnapshot(filename) {
            let url = layout.recordings.appendingPathComponent(filename)
            let touched = redactIndex(at: url, name: name, with: replacement)
            if touched > 0 {
                entriesChanged += touched
                changed.append(filename)
            }
        }

        return PersonErasureReport(
            entriesChanged: entriesChanged,
            filesChanged: changed,
            remaining: remaining(person: raw, in: layout)
        )
    }

    /// Файлы архива, в которых имя ещё встречается. Тем же поиском, которым
    /// стирали.
    public static func remaining(person raw: String, in layout: ArchiveLayout) -> [String] {
        let name = PersonName(raw)
        guard !name.isEmpty else { return [] }
        var left: [String] = []

        for filename in ArchiveEraser.filenames(in: layout.meetings) where filename.hasSuffix(".md") {
            let url = layout.meetings.appendingPathComponent(filename)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if PersonErasure.contains(filename, name: name) || PersonErasure.contains(text, name: name) {
                left.append(filename)
            }
        }

        for filename in ArchiveEraser.filenames(in: layout.recordings)
        where filename == ArchiveLayout.indexName
            || ArchiveLayout.isIndexSnapshot(filename)
            || filename == ArchiveLayout.tombstonesName {
            let url = layout.recordings.appendingPathComponent(filename)
            // Сырым текстом намеренно: индекс пишется в UTF-8 без экранирования,
            // а вложенный JSON (`mergedSegmentsJSON`) в нём — строка, где имя
            // лежит как есть. Разбор структуры тут ответил бы про поля, которые
            // мы знаем, а спросить надо про файл целиком.
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if PersonErasure.contains(text, name: name) { left.append(filename) }
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
}
