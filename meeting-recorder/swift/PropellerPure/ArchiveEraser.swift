import Foundation

/// # Стирание, доведённое до диска
///
/// Правило живёт в `MeetingErasure` и проверяется без файловой системы. Здесь —
/// исполнение, и оно в `PropellerPure` по той же причине, по которой здесь лежит
/// `WavHeader`: свойство «после стирания не осталось ни одного следа» проверяется
/// только на настоящем каталоге, а `Sources/` тестам недоступен. Фикстуры теста
/// — во временных каталогах; на архив живого человека этот код смотрит ровно
/// одним способом — тем, которым его позвал сам человек.
///
/// ## Порядок шагов — это и есть надёжность
///
/// 1. **Надгробие пишется первым**, синхронно. Всё остальное можно не докончить:
///    том отмонтировали, файл занят, процесс убили. Камень — единственное, что
///    после этого расскажет скану сирот, что незакрытое удаление было
///    (`OrphanAdoption`).
/// 2. **Файлы.** Все, чьё имя несёт id, а не список известных видов.
/// 3. **Индекс — синхронно, без дебаунса.** У удаления не бывает «сохраним через
///    0,2 с»: ровно в это окно процесс и умирает.
/// 4. **Копии индекса** — `.bak`, карантинные `corrupt-*`, снятые руками —
///    чистятся поэлементно: из каждой вынимается одна запись, файл остаётся.
///    Удалять снимок целиком нельзя: это единственный путь восстановления **всех
///    остальных** встреч, и стирание одной не имеет права его уносить. Снимок,
///    не разбирающийся в массив объектов вовсе, докладывается как оставшийся
///    след: соврать «следов нет» про нечитаемый файл нельзя.
/// 5. **Публикация — метка, а не удаление.** Копию саммари с сервера снимает
///    только сеть, а удаление встречи ждать сети не имеет права. Поэтому запись
///    в `shares.json` не уходит вместе со встречей: она получает `erasedAt` и
///    остаётся списком того, что осталось отозвать (`ShareStore`). В отчёт этот
///    след идёт как оставшийся — потому что он и правда остался.
/// 6. **Камень снимается последним и только если больше ничего не осталось** —
///    ничего из того, что стирание умеет убрать. Не удалось стереть файл — камень
///    остаётся, и скан сирот доведёт дело. Осталась одна публикация — камень
///    уходит: скан сирот в сеть не ходит и довести её не может, а держать камень
///    ради чужой работы значит оставить его навсегда.
public enum ArchiveEraser {

    // MARK: - Снимок архива

    /// Что сейчас лежит в архиве. Один проход по двум каталогам плюс чтение
    /// индекса, его копий и надгробий.
    public static func survey(_ layout: ArchiveLayout, at now: Date = Date()) -> MeetingTraceSurvey {
        let recordingsFiles = filenames(in: layout.recordings)
        let meetingsFiles = filenames(in: layout.meetings)

        var snapshotIDs = Set<String>()
        for name in recordingsFiles where ArchiveLayout.isIndexSnapshot(name) {
            let url = layout.recordings.appendingPathComponent(name)
            snapshotIDs.formUnion(IndexFile.ids(at: url))
        }

        return MeetingTraceSurvey(
            recordingsFiles: recordingsFiles,
            meetingsFiles: meetingsFiles,
            indexIDs: IndexFile.ids(at: layout.indexURL),
            snapshotIDs: Array(snapshotIDs),
            tombstoneIDs: TombstoneFile.read(layout.tombstonesURL).map(\.id),
            publishedIDs: ShareStore.liveIDs(at: layout.shares, now: now)
        )
    }

    /// Что от встречи осталось. То же, что вернуло стирание, — и то, что
    /// проверяет тест.
    public static func residue(of id: String, in layout: ArchiveLayout, at now: Date = Date()) -> MeetingResidue {
        MeetingErasure.residue(of: id, in: survey(layout, at: now))
    }

    // MARK: - Стереть одну встречу

    /// Стереть встречу целиком. Возвращает то, что после этого осталось; пусто —
    /// значит следов не осталось нигде.
    ///
    /// Остаток бывает двух пород, и они разные. Не удалось стереть файл — это
    /// сбой, камень остаётся, дочистка придёт. Осталась `.publishedShare` — это
    /// не сбой: копия саммари лежит на сервере, снять её можно только по сети, и
    /// вызывающий обязан завести отзыв (`ShareService.finishPendingRevocations`),
    /// а не считать удаление незаконченным.
    ///
    /// Идемпотентно: повторный вызов на уже стёртой встрече не пишет ни байта и
    /// возвращает либо пусто, либо ту же неснятую публикацию.
    @discardableResult
    public static func erase(meeting id: String, in layout: ArchiveLayout, at now: Date = Date()) -> MeetingResidue {
        guard !id.isEmpty else { return MeetingResidue() }
        let before = survey(layout, at: now)
        let residueBefore = MeetingErasure.residue(of: id, in: before)
        guard !residueBefore.isEmpty else { return MeetingResidue() }
        // Осталась одна публикация, и она уже помечена — локально сделано всё,
        // дальше очередь сети. Без этой ветки повторный вызов ставил бы и снимал
        // камень на каждом скане сирот до самого истечения срока ссылки.
        if residueBefore.kinds == [.publishedShare], residueBefore.unclassifiedFiles.isEmpty,
           ShareStore.isAwaitingRevocation(id, at: layout.shares) {
            return residueBefore
        }

        // 1. Камень — до того, как тронули хоть один файл.
        TombstoneFile.mark(id, in: layout, at: now)

        // 1a. Публикация: снять её можно только по сети, а удаление сети не ждёт.
        //     Метка синхронная, как и камень; запись с токеном остаётся жить и
        //     служит очередью отзыва (`ShareService.finishPendingRevocations`).
        //     Не вышло пометить — врать не пришлось: запись осталась на месте,
        //     значит `.publishedShare` всё равно уедет в отчёт ниже.
        ShareStore.markErased(id, at: layout.shares, now: now)

        // 2. Файлы: правило по имени, поэтому производная, появившаяся после
        //    этого кода, уходит вместе со всеми.
        let fm = FileManager.default
        let mine = MeetingErasure.files(of: id, in: before)
        for name in mine.recordings {
            try? fm.removeItem(at: layout.recordings.appendingPathComponent(name))
        }
        for name in mine.meetings {
            try? fm.removeItem(at: layout.meetings.appendingPathComponent(name))
        }

        // 3. Живой индекс, синхронно.
        IndexFile.removingEntries(withIDs: [id], at: layout.indexURL)

        // 4. Копии индекса.
        scrubSnapshots(ids: [id], in: layout)

        // 5. Камень уходит, только если не осталось ничего, что стирание умеет
        //    убрать. Публикация в этот счёт не входит: её снимает сеть, а скан
        //    сирот, ради которого камень и лежит, в сеть не ходит. Камень над
        //    ней стоял бы до истечения срока ссылки и ничего бы не двигал.
        var after = MeetingErasure.residue(of: id, in: survey(layout, at: now))
        after.kinds.remove(.tombstone)
        let erasable = after.kinds.subtracting([.publishedShare])
        if erasable.isEmpty, after.unclassifiedFiles.isEmpty {
            TombstoneFile.unmark(id, in: layout)
            // Пусто, если публикации не было; иначе — она одна, и отчёт о ней
            // говорит: ссылка ещё жива, отозвать её есть чем.
            return after
        }
        after.kinds.insert(.tombstone)
        return after
    }

    /// Дочистить незакрытые удаления: у каждого надгробия, чьи следы ещё лежат на
    /// диске, довести стирание до конца. Возвращает id, по которым что-то
    /// доделали.
    ///
    /// Раньше это делал скан сирот, и только для аудио: 24 МБ от одной удалённой
    /// встречи переживали штатный выход (замерено 2026-08-09), а расшифровка и
    /// конспект переживали его всегда.
    ///
    /// - Parameter keeping: встреча, чьё «Вернуть» ещё на экране. Её трогать
    ///   нельзя: отмена, которая не может вернуть файлы, — не отмена.
    @discardableResult
    public static func finishPendingErasures(
        in layout: ArchiveLayout, keeping undoableID: String? = nil
    ) -> [String] {
        var finished: [String] = []
        for stone in TombstoneFile.read(layout.tombstonesURL) where stone.id != undoableID {
            let before = MeetingErasure.residue(of: stone.id, in: survey(layout))
            // Один только камень — стирание уже доведено; `erase` в этом случае
            // ничего не удаляет и просто снимает камень, поэтому отдельной ветки
            // тут нет. Считается доделанным только то, где что-то и правда было.
            // Публикация из счёта исключена: `erase` её не убирает, и считать
            // доделанным то, чего не делали, значит писать в лог неправду.
            let hadMore = before.kinds.subtracting([.tombstone, .publishedShare]).isEmpty == false
                || !before.unclassifiedFiles.isEmpty
            erase(meeting: stone.id, in: layout, at: stone.at)
            if hadMore { finished.append(stone.id) }
        }
        return finished
    }

    // MARK: - Копии индекса

    /// Вынуть записи из всех копий индекса.
    ///
    /// Одним правилом для `.bak`, карантина и снимка, снятого руками: копия
    /// остаётся копией, из неё уходит одна запись. Смысл резерва — что резерв
    /// есть; резерв, хранящий удалённое, — это не резерв, а второй экземпляр, но
    /// удалить его целиком значит унести и все остальные встречи.
    @discardableResult
    static func scrubSnapshots(ids: Set<String>, in layout: ArchiveLayout) -> [String] {
        var failed: [String] = []
        for name in filenames(in: layout.recordings) where ArchiveLayout.isIndexSnapshot(name) {
            let url = layout.recordings.appendingPathComponent(name)
            if !IndexFile.removingEntries(withIDs: ids, at: url) { failed.append(name) }
        }
        return failed
    }

    // MARK: - Каталоги

    static func filenames(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }
}

// MARK: - Индекс как файл

/// Индекс и его копии, читаемые **без** `RecordingEntry`.
///
/// Терпимо и по-элементно: стирание обязано работать на карантинной копии,
/// которая в карантине именно потому, что целиком не разбирается. Незнакомое
/// поле при этом переживает перезапись — запись не пересобирается по известной
/// схеме, а переносится как есть.
public enum IndexFile {

    /// Записи файла, или nil, если это вообще не массив объектов.
    ///
    /// Требование «каждый элемент — объект» строгое намеренно: `compactMap`
    /// молча выбросил бы всё непонятное, перезапись сохранила бы усечённый файл,
    /// а проверка следов сказала бы «чисто» про текст, в котором запись ещё
    /// лежит. Не разобралось — значит нечитаемо, и об этом надо доложить.
    public static func entries(at url: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        let objects = array.compactMap { $0 as? [String: Any] }
        guard objects.count == array.count else { return nil }
        return objects
    }

    /// id, лежащие в файле. У нечитаемого файла — найденные в тексте: «не
    /// разобралось» не имеет права читаться как «пусто», иначе проверка следов
    /// объявит чистым снимок, в котором запись цела.
    public static func ids(at url: URL) -> [String] {
        if let entries = entries(at: url) {
            return entries.compactMap { $0["id"] as? String }
        }
        return rawIDs(at: url)
    }

    /// Записать записи обратно. `false` — не удалось, вызывающий обязан
    /// доложить, а не промолчать.
    @discardableResult
    public static func write(_ entries: [[String: Any]], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: []) else {
            return false
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Убрать записи с этими id. `true`, если файла нет, убирать нечего или
    /// перезапись удалась; `false` — файл есть, id в нём есть, а вынуть не
    /// вышло.
    @discardableResult
    public static func removingEntries(withIDs ids: Set<String>, at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let entries = entries(at: url) else {
            // Не массив объектов вовсе — програмно вынуть запись нечем. Удалять
            // файл целиком тем более нельзя: неизвестно, что в нём.
            return ids.isDisjoint(with: Set(rawIDs(at: url)))
        }
        let kept = entries.filter { entry in
            guard let id = entry["id"] as? String else { return true }
            return !ids.contains(id)
        }
        guard kept.count != entries.count else { return true }
        return write(kept, to: url)
    }

    /// Последний рубеж для файла, который не разобрался: есть ли в нём вообще
    /// эта строка. Нужен, чтобы не соврать «следов нет» про нечитаемый снимок.
    static func rawIDs(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // Ищем `"id":"<...>"` без разбора структуры: структуры тут и нет.
        var found: [String] = []
        let pattern = #""id"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            found.append(String(text[r]))
        }
        return found
    }
}

// MARK: - Надгробия как файл

/// `deleted.json`. Раньше читался и писался приватно внутри `RecordingStore`;
/// вынесен, потому что камень — часть модели стирания, а не деталь хранилища, и
/// теперь его ставят и снимают два вызывающих: мягкое удаление (⌘Z) и стирание.
public enum TombstoneFile {

    public static func read(_ url: URL) -> [MeetingTombstone] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MeetingTombstone].self, from: data)) ?? []
    }

    @discardableResult
    public static func write(_ stones: [MeetingTombstone], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stones) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Поставить камень. Синхронно и без дебаунса — весь его смысл в том, чтобы
    /// пережить `SIGKILL`, а дебаунс на 0,2 с это ровно то окно, в котором он его
    /// не переживёт.
    @discardableResult
    public static func mark(_ id: String, in layout: ArchiveLayout, at now: Date = Date()) -> Bool {
        var stones = read(layout.tombstonesURL)
        guard !stones.contains(where: { $0.id == id }) else { return true }
        stones.append(MeetingTombstone(id: id, at: now))
        try? FileManager.default.createDirectory(
            at: layout.recordings, withIntermediateDirectories: true
        )
        return write(stones, to: layout.tombstonesURL)
    }

    @discardableResult
    public static func unmark(_ id: String, in layout: ArchiveLayout) -> Bool {
        let stones = read(layout.tombstonesURL)
        guard stones.contains(where: { $0.id == id }) else { return true }
        return write(stones.filter { $0.id != id }, to: layout.tombstonesURL)
    }
}
