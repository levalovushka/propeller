import Foundation

/// # Стереть встречу — и знать, что стёрли
///
/// Удаление было половинчатым, и это не догадка: `RecordingStore.remove`
/// убирал аудио и строку индекса, а расшифровка и конспект оставались в
/// `meetings/` навсегда (STATE, компонент 5, rev-9). Плюс два следа, которых
/// в том разборе не было вовсе: `recordings.json.bak` — снимок прежнего
/// индекса, где удалённая встреча ещё лежит целиком, вместе с транскриптом, — и
/// карантинные копии `recordings.json.corrupt-*`, живущие на диске вечно.
///
/// ## Почему правило по имени файла, а не по списку видов
///
/// Скоро у встречи появятся атомы (утверждение + автор + время + проект +
/// таймкод), а за ними ещё что-нибудь. Модель удаления, перечисляющая виды
/// производных, ломается ровно в этот момент: кто-то добавит `<id>-atoms.json` и
/// не вспомнит про удаление, а узнается это через год у живого человека.
///
/// Поэтому стирание спрашивает **«несёт ли имя файла id встречи»**
/// (`MeetingErasure.belongs`), а не «какой это вид». Новая производная,
/// названная по встрече, удаляется тем же кодом, который не менялся.
/// `MeetingTrace` при этом остаётся — но не как список того, что удалять, а как
/// список того, что обязана содержать фикстура теста: перечисление с
/// исчерпывающим `switch`, поэтому новый вид следа не собирается, пока про него
/// не сказали, где он лежит.
///
/// Файл, который несёт id и ни на один известный вид не похож, стирается и
/// **докладывается** (`MeetingResidue.unclassifiedFiles`). Это не ошибка — так
/// выглядит производная, появившаяся позже этого кода.
public enum MeetingTrace: String, CaseIterable, Sendable {
    /// `recordings/<id>.wav` — финальный микс.
    case audioMix
    /// `recordings/<id>.mic.wav` — микрофонный стем.
    case audioMicrophoneStem
    /// `recordings/<id>.sys.wav` — системный стем.
    case audioSystemStem
    /// `meetings/<id>-<slug>.md` — расшифровка.
    case transcriptDocument
    /// `meetings/<id>-<slug>-recap.md` — конспект.
    case recapDocument
    /// Строка в `recordings.json`. Носит на себе транскрипт, заметки, чекпоинт
    /// ASR (`rawSegmentsJSON`), сегменты со спикерами, черновик живого текста,
    /// темы, теги и календарные данные — всё это поля одной строки, а не
    /// отдельные файлы, поэтому у них один след.
    case indexEntry
    /// Та же строка в любой копии индекса: `recordings.json.bak`,
    /// `recordings.json.corrupt-<stamp>`, снимок, снятый руками. Копию не
    /// удаляют — из неё вынимают одну запись, иначе стирание одной встречи
    /// уносило бы единственный путь восстановления всех остальных.
    case indexSnapshotEntry
    /// Надгробие в `deleted.json` — id и дата удаления. След слабый, но след:
    /// он говорит, что встреча с таким временем была. Уходит последним и только
    /// когда не осталось ничего другого.
    case tombstone
}

/// Где лежит архив. Один тип вместо двух строк из настроек, разбросанных по
/// вызывающим: путь к копии индекса и к надгробиям выводится отсюда, а не
/// собирается заново в каждом месте.
public struct ArchiveLayout: Equatable, Sendable {
    public let recordings: URL
    public let meetings: URL

    public init(recordings: URL, meetings: URL) {
        self.recordings = recordings
        self.meetings = meetings
    }

    public init(recordingsPath: String, meetingsPath: String) {
        self.init(
            recordings: URL(fileURLWithPath: recordingsPath),
            meetings: URL(fileURLWithPath: meetingsPath)
        )
    }

    public static let indexName = "recordings.json"
    public static let tombstonesName = "deleted.json"

    public var indexURL: URL { recordings.appendingPathComponent(Self.indexName) }
    public var tombstonesURL: URL { recordings.appendingPathComponent(Self.tombstonesName) }

    /// Копия индекса — любой файл, чьё имя начинается с имени индекса и им не
    /// равен: `.bak`, `.corrupt-<stamp>`, `.pre-restore-<stamp>`. Правило по
    /// префиксу намеренно: снимки снимает не только приложение, и следующий вид
    /// снимка не должен требовать правки этого кода.
    public static func isIndexSnapshot(_ filename: String) -> Bool {
        filename.hasPrefix(indexName) && filename != indexName
    }
}

/// Что от встречи осталось. Возвращается стиранием и считается тем же кодом,
/// которым проверяет тест, — одна функция, два вызывающих, дрейфовать нечему.
public struct MeetingResidue: Equatable, Sendable {
    /// Известные виды следов, ещё лежащие в архиве.
    public var kinds: Set<MeetingTrace>
    /// Файлы, несущие id встречи и не похожие ни на один известный вид.
    public var unclassifiedFiles: [String]

    public init(kinds: Set<MeetingTrace> = [], unclassifiedFiles: [String] = []) {
        self.kinds = kinds
        self.unclassifiedFiles = unclassifiedFiles.sorted()
    }

    public var isEmpty: Bool { kinds.isEmpty && unclassifiedFiles.isEmpty }

    /// Для лога и отчёта: чего именно не удалось стереть.
    public var summary: String {
        let list = kinds.map(\.rawValue).sorted() + unclassifiedFiles
        return list.joined(separator: ", ")
    }
}

/// Снимок архива по одной встрече, снятый до решения. Отделён от диска, чтобы
/// правило проверялось без файловой системы, а стирание и проверка смотрели на
/// одни и те же данные.
public struct MeetingTraceSurvey: Equatable, Sendable {
    /// Имена файлов в `recordings/`.
    public var recordingsFiles: [String]
    /// Имена файлов в `meetings/`.
    public var meetingsFiles: [String]
    /// id, встречающиеся в живом индексе.
    public var indexIDs: [String]
    /// id, встречающиеся хотя бы в одной копии индекса.
    public var snapshotIDs: [String]
    /// id из `deleted.json`.
    public var tombstoneIDs: [String]

    public init(
        recordingsFiles: [String] = [],
        meetingsFiles: [String] = [],
        indexIDs: [String] = [],
        snapshotIDs: [String] = [],
        tombstoneIDs: [String] = []
    ) {
        self.recordingsFiles = recordingsFiles
        self.meetingsFiles = meetingsFiles
        self.indexIDs = indexIDs
        self.snapshotIDs = snapshotIDs
        self.tombstoneIDs = tombstoneIDs
    }
}

public enum MeetingErasure {

    /// Принадлежит ли файл этой встрече.
    ///
    /// Разделитель обязателен: без него `20260101_120000` совпал бы с началом
    /// чужого имени. С форматом id (`yyyyMMdd_HHmmss`, фиксированная длина)
    /// столкновение и так невозможно, но правило не должно держаться на длине
    /// строки — id однажды сменит форму.
    public static func belongs(_ filename: String, to id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if filename == id { return true }
        return filename.hasPrefix(id + ".") || filename.hasPrefix(id + "-")
    }

    /// Какой это вид следа, если вид известен.
    ///
    /// `switch` исчерпывающий по видам файлов, а не по `allCases`: разбор идёт от
    /// имени к виду. Проверку «ни один вид не забыт» держит тест, обходящий
    /// `MeetingTrace.allCases`.
    public static func kind(of filename: String, for id: String) -> MeetingTrace? {
        guard belongs(filename, to: id) else { return nil }
        if filename == "\(id).wav" { return .audioMix }
        if filename == "\(id).mic.wav" { return .audioMicrophoneStem }
        if filename == "\(id).sys.wav" { return .audioSystemStem }
        if RecapFile.isRecap(filename, for: id) { return .recapDocument }
        if RecapFile.isTranscript(filename, for: id) { return .transcriptDocument }
        return nil
    }

    /// Файлы архива, принадлежащие встрече, — то, что стирание удаляет.
    public static func files(of id: String, in survey: MeetingTraceSurvey) -> (recordings: [String], meetings: [String]) {
        (
            survey.recordingsFiles.filter { belongs($0, to: id) },
            survey.meetingsFiles.filter { belongs($0, to: id) }
        )
    }

    /// Что от встречи ещё осталось.
    ///
    /// Обход идёт по `MeetingTrace.allCases` намеренно: новый вид следа не
    /// соберётся, пока в `switch` не сказали, как его найти, — и тогда же он
    /// попадёт и в проверку, и в отчёт. Это и есть готовность к атомам.
    public static func residue(of id: String, in survey: MeetingTraceSurvey) -> MeetingResidue {
        let mine = files(of: id, in: survey)
        var kinds = Set<MeetingTrace>()

        for trace in MeetingTrace.allCases {
            let present: Bool
            switch trace {
            case .audioMix, .audioMicrophoneStem, .audioSystemStem:
                present = mine.recordings.contains { kind(of: $0, for: id) == trace }
            case .transcriptDocument, .recapDocument:
                present = mine.meetings.contains { kind(of: $0, for: id) == trace }
            case .indexEntry:
                present = survey.indexIDs.contains(id)
            case .indexSnapshotEntry:
                present = survey.snapshotIDs.contains(id)
            case .tombstone:
                present = survey.tombstoneIDs.contains(id)
            }
            if present { kinds.insert(trace) }
        }

        let unclassified = (mine.recordings + mine.meetings)
            .filter { kind(of: $0, for: id) == nil }
        return MeetingResidue(kinds: kinds, unclassifiedFiles: unclassified)
    }
}
