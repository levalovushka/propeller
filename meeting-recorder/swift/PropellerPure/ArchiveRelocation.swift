import Foundation

/// # Сменить папку архива — значит перенести архив
///
/// До этого «Изменить…» в настройках писала новый путь в `Preferences` и на
/// этом заканчивалась. Наблюдателей у пути нет, миграции нет, предупреждения
/// нет — а читателей семнадцать, и каждый на следующем же обращении смотрит
/// в новую папку. Что человек получал молча:
///
/// - **индекс** уезжал сам: первая же правка вызывала `save()`, и весь массив
///   из памяти ложился в новую папку — вместе с транскриптами. Если там уже
///   лежал архив Пропеллера, его `recordings.json` перезаписывался чужим;
/// - **аудио** оставалось в старой, `audioURL` смотрел в новую, и каждая
///   встреча читалась как «аудио удалено»;
/// - **расшифровки и конспекты** при смене «Папки заметок» оставались позади,
///   а MCP-сервер читал новую — саммари всего архива пропадали разом;
/// - **надгробия**: `finishPendingErasures` читал `deleted.json` новой папки,
///   и незакрытые удаления в старой не дочищались никогда — аудио и текст
///   удалённой встречи оставались на диске навсегда.
///
/// Человек при этом считал, что перенёс архив.
///
/// ## Почему перенос, а не запрет и не молчаливая смена
///
/// Запрет («папку нельзя менять, пока архив не пуст») — тупик из
/// `design/no-dead-ends.md`: кнопка есть, нажимается и отказывает. У человека,
/// которому архив надо унести на внешний диск, не остаётся ничего, кроме
/// Finder и веры, что он угадал состав архива.
///
/// Молчаливый перенос врёт по-другому: перенос **может не доехать** — том
/// отмонтировали, файл занят, в цели уже лежит файл с тем же именем. Молчание
/// про половину переехавшего архива хуже, чем сегодняшнее молчание.
///
/// Поэтому решение принимается **до** первого сдвинутого байта, вслух, и здесь:
/// что переедет, что останется позади и почему перенос вообще невозможен —
/// считается без диска и проверяется тестом. Экран настроек читает систему,
/// показывает названное и жмёт кнопку.
///
/// ## Что считается нашим
///
/// Папка заметок у обсидиановода — это папка **внутри его хранилища**, где
/// кроме наших расшифровок лежат его собственные заметки. Унести их вместе с
/// архивом нельзя: это чужие данные, которые никто не просил трогать. Поэтому
/// переезжает не «всё содержимое папки», а то, что Пропеллер опознаёт своим
/// (`ArchiveRelocation.isOurs`), а всё остальное **называется вслух** как
/// оставшееся позади.
public enum ArchiveRelocation {

    // MARK: - Что лежит в папке

    /// Снимок папки, снятый до решения. Отделён от диска, чтобы правило
    /// проверялось без файловой системы, — так же, как `MeetingTraceSurvey`.
    public struct Folder: Equatable, Sendable {
        /// Путь, как его показывают человеку.
        public var path: String
        /// Имена файлов первого уровня. Пусто и «папки нет» здесь одно и то же:
        /// для решения это одинаково «переносить нечего / места хватит».
        public var filenames: [String]
        /// Можно ли туда писать. У несуществующей папки — можно ли её создать.
        public var isWritable: Bool

        public init(path: String, filenames: [String] = [], isWritable: Bool = true) {
            self.path = path
            self.filenames = filenames
            self.isWritable = isWritable
        }
    }

    /// Почему перенос невозможен. Отказ, а не предупреждение: оба случая
    /// кончаются потерянными данными, если их продавить.
    public enum Obstacle: Equatable, Sendable {
        /// В новую папку нельзя писать. Менять путь бессмысленно и без
        /// переноса: туда не ляжет и следующая запись.
        case targetNotWritable
        /// В новой папке уже лежит архив, и его файлы называются так же.
        /// Перенос затёр бы чужой `recordings.json` — то есть чужой архив
        /// целиком, потому что транскрипты лежат строками в нём.
        case targetHoldsArchive(colliding: [String])
    }

    /// Что будет, если нажать «Перенести».
    public struct Plan: Equatable, Sendable {
        /// Имена файлов в порядке переноса. Порядок — часть плана, см.
        /// `ordered`.
        public var carried: [String]
        /// Чужие файлы, остающиеся в старой папке. Не ошибка — их никто и не
        /// просил трогать, но человек обязан узнать об этом до нажатия.
        public var leftBehind: [String]
        /// Сколько чужих файлов уже лежит в новой папке. Столкновений имён у
        /// них нет (иначе был бы `Obstacle`), но «папка не пустая» — это то,
        /// что человек хочет знать до, а не после.
        public var joins: Int

        public init(carried: [String], leftBehind: [String] = [], joins: Int = 0) {
            self.carried = carried
            self.leftBehind = leftBehind
            self.joins = joins
        }
    }

    /// Ответ на «что произойдёт, если сменить папку на эту».
    public enum Verdict: Equatable, Sendable {
        /// Ткнули в ту же папку. Делать нечего и говорить не о чем.
        case sameFolder
        /// Нашего в старой папке нет — менять путь можно молча.
        case nothingToCarry
        /// Можно перенести, и вот что переедет.
        case carry(Plan)
        /// Нельзя, и вот почему.
        case refused(Obstacle)
    }

    // MARK: - Правило

    /// Файлы архива, которые Пропеллер узнаёт своими.
    ///
    /// Правило по имени, а не по списку видов, — по той же причине, что и в
    /// `MeetingErasure.belongs`: новая производная, названная по встрече,
    /// переедет тем же кодом, который не менялся. Всё, что не опознано,
    /// остаётся на месте: чужую заметку из хранилища Обсидиана уносить нельзя.
    public static func isOurs(_ filename: String) -> Bool {
        if filename == ArchiveLayout.indexName
            || filename == ArchiveLayout.tombstonesName
            || filename == ArchiveLayout.projectsName
            || filename == ArchiveLayout.silencedProjectsName {
            return true
        }
        if ArchiveLayout.isIndexSnapshot(filename) { return true }
        return carriesMeetingID(filename)
    }

    /// Несёт ли имя файла id встречи (`yyyyMMdd_HHmmss`).
    ///
    /// Разделитель после id обязателен ровно по доводу `MeetingErasure.belongs`:
    /// без него совпало бы начало чужого имени. Форма проверяется посимвольно,
    /// а не разбором даты: `20261332_997788` — не настоящая дата, но это всё
    /// равно наш файл, если так назвалась встреча.
    public static func carriesMeetingID(_ filename: String) -> Bool {
        let c = Array(filename)
        guard c.count >= 15, c[8] == "_" else { return false }
        for i in 0..<8 where !isDigit(c[i]) { return false }
        for i in 9..<15 where !isDigit(c[i]) { return false }
        if c.count == 15 { return true }
        return c[15] == "." || c[15] == "-"
    }

    private static func isDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isNumber }

    /// Одна ли это папка. Сравнение по нормализованному пути: `~/a/` и `~/a`
    /// — одно место, а отказ «папка занята сама собой» выглядел бы поломкой.
    public static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: ArchivePath.normalized(path, default: path))
            .standardizedFileURL
            .path
    }

    /// Что произойдёт при смене папки. Ни одного обращения к диску.
    ///
    /// Порядок проверок — это порядок цены ошибки. «Та же папка» первой, иначе
    /// собственные файлы архива прочитались бы как столкновение имён. «Нельзя
    /// писать» — раньше, чем «нечего переносить»: в папку, куда не пишут, не
    /// ляжет и следующая запись, и пустой архив это не спасает.
    public static func verdict(from source: Folder, to target: Folder) -> Verdict {
        if sameFolder(source.path, target.path) { return .sameFolder }
        if !target.isWritable { return .refused(.targetNotWritable) }

        let ours = source.filenames.filter(isOurs)
        let theirs = source.filenames.filter { !isOurs($0) }

        let occupied = Set(target.filenames)
        let colliding = ours.filter(occupied.contains).sorted()
        if !colliding.isEmpty { return .refused(.targetHoldsArchive(colliding: colliding)) }

        if ours.isEmpty { return .nothingToCarry }

        return .carry(
            Plan(
                carried: ordered(ours),
                leftBehind: theirs.sorted(),
                joins: target.filenames.count
            )
        )
    }

    /// Порядок переноса: индекс уходит последним.
    ///
    /// Путь в настройках переключается **после** переноса, то есть всё время,
    /// пока файлы едут, живое приложение читает старую папку. Если индекс уедет
    /// первым, архив на эти секунды станет пустым на экране; если процесс
    /// умрёт на середине — старая папка останется без индекса, то есть без
    /// единственного места, где лежат транскрипты. Поэтому:
    /// сначала данные встреч, потом сопутствующие файлы, `recordings.json` —
    /// последним.
    ///
    /// Гонку это не закрывает: запись, дошедшая до `save()` посреди переноса,
    /// всё ещё уйдёт в старую папку. Закрыть её можно только остановив конвейер,
    /// а он живёт не здесь; цена названа вслух и записана как открытый хвост.
    static func ordered(_ filenames: [String]) -> [String] {
        filenames.sorted { lhs, rhs in
            let (l, r) = (rank(lhs), rank(rhs))
            return l == r ? lhs < rhs : l < r
        }
    }

    private static func rank(_ filename: String) -> Int {
        if filename == ArchiveLayout.indexName { return 2 }
        if filename == ArchiveLayout.tombstonesName
            || filename == ArchiveLayout.projectsName
            || filename == ArchiveLayout.silencedProjectsName
            || ArchiveLayout.isIndexSnapshot(filename) {
            return 1
        }
        return 0
    }

    // MARK: - Исполнение

    /// Что доехало и что нет.
    ///
    /// Половина архива в одной папке и половина в другой — состояние хуже
    /// обоих исходных, и продукт не имеет права его оставлять: путь читают
    /// семнадцать мест, и каждое увидит ровно половину. Поэтому перенос
    /// встаёт на первой же неудаче и **возвращает доехавшее назад**. Успех —
    /// это весь архив в новой папке; неудача — весь архив в старой.
    public struct Outcome: Equatable, Sendable {
        /// Что сейчас лежит в новой папке. При удаче — весь план; при неудаче с
        /// удавшимся откатом — пусто.
        public var moved: [String]
        /// Имя файла, на котором перенос встал. Nil — доехало всё.
        public var stoppedAt: String?
        /// Что не удалось вернуть назад. Пусто — архив снова целиком в старой
        /// папке. Непусто — единственный случай, когда архив всё-таки разорван,
        /// и назвать его человеку обязательно.
        public var stranded: [String]

        public init(moved: [String] = [], stoppedAt: String? = nil, stranded: [String] = []) {
            self.moved = moved
            self.stoppedAt = stoppedAt
            self.stranded = stranded
        }

        public var isComplete: Bool { stoppedAt == nil }
    }

    /// Снять состояние папки с диска.
    ///
    /// У несуществующей папки спрашивается родитель: её ещё предстоит создать,
    /// и «нельзя писать» надо узнать до, а не в середине переноса.
    public static func survey(_ path: String) -> Folder {
        let fm = FileManager.default
        let clean = ArchivePath.normalized(path, default: path)
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: clean, isDirectory: &isDir) && isDir.boolValue
        let probe = exists
            ? clean
            : URL(fileURLWithPath: clean).deletingLastPathComponent().path
        return Folder(
            path: clean,
            filenames: exists ? ((try? fm.contentsOfDirectory(atPath: clean)) ?? []) : [],
            isWritable: fm.isWritableFile(atPath: probe)
        )
    }

    /// Перенести. Файл за файлом, в порядке плана, ничего не удаляя.
    ///
    /// Внутри тома `moveItem` — переименование, то есть мгновенно и без копии
    /// мегабайтов; между томами он сам копирует и удаляет исходник. Не звать с
    /// главного потока: между томами это настоящий копир архива.
    ///
    /// Первая же неудача откатывает уже переехавшее (см. `Outcome`): архив
    /// либо весь там, либо весь тут.
    @discardableResult
    public static func perform(_ plan: Plan, from source: String, to target: String) -> Outcome {
        let fm = FileManager.default
        let from = URL(fileURLWithPath: ArchivePath.normalized(source, default: source))
        let to = URL(fileURLWithPath: ArchivePath.normalized(target, default: target))

        do {
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
        } catch {
            // Папки нет и не будет — не доехало ничего.
            return Outcome(stoppedAt: plan.carried.first)
        }

        var done: [String] = []
        for name in plan.carried {
            do {
                try fm.moveItem(
                    at: from.appendingPathComponent(name),
                    to: to.appendingPathComponent(name)
                )
                done.append(name)
            } catch {
                // Откат в обратном порядке: индекс уходил последним, значит и
                // возвращается первым — старая папка становится читаемым
                // архивом раньше, чем закончится откат.
                var stranded: [String] = []
                for back in done.reversed() {
                    do {
                        try fm.moveItem(
                            at: to.appendingPathComponent(back),
                            to: from.appendingPathComponent(back)
                        )
                    } catch {
                        stranded.append(back)
                    }
                }
                return Outcome(
                    moved: stranded.sorted(),
                    stoppedAt: name,
                    stranded: stranded.sorted()
                )
            }
        }
        return Outcome(moved: done)
    }
}
