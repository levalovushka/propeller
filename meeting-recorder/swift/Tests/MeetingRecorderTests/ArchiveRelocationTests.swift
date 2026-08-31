import XCTest
@testable import PropellerPure

/// # «Я же перенёс архив»
///
/// Названо по тому, что человек думал, нажимая «Изменить…» у папки записей.
/// Приложение писало новый путь и молчало: индекс уезжал сам первой же
/// правкой, аудио оставалось позади и каждая встреча читалась как «аудио
/// удалено», а надгробия из старой папки не дочищались уже никогда.
///
/// Здесь проверяется решение, которое теперь принимается **до** первого
/// сдвинутого байта, и перенос, который либо доезжает целиком, либо
/// возвращается назад.
final class ArchiveRelocationTests: XCTestCase {

    // MARK: - Что считается нашим

    func testФайлыАрхиваУзнаютсяПоИмени() {
        for name in [
            "recordings.json", "deleted.json", "projects.json", "projects-silenced.json",
            "recordings.json.bak", "recordings.json.corrupt-20260830_101010",
            "20260821_103440.wav", "20260821_103440.mic.wav",
            "20260821_103440.calltrace.jsonl",
            "20260821_103440-разбор-джоб.md", "20260821_103440-разбор-джоб-recap.md",
            "20260821_103440",
        ] {
            XCTAssertTrue(ArchiveRelocation.isOurs(name), name)
        }
    }

    /// Папка заметок у обсидиановода — папка внутри его хранилища. Унести его
    /// собственные заметки вместе с архивом нельзя: это чужие данные.
    func testЧужиеЗаметкиНеСчитаютсяНашими() {
        for name in [
            "Идеи.md", "Daily/2026-08-21.md", ".DS_Store",
            "2026-08-21.md", "20260821.wav", "20260821_10344.wav", "202608211_103440.wav",
            "20260821x103440.wav", "20260821_10344a.wav", "20260821_103440x.wav",
        ] {
            XCTAssertFalse(ArchiveRelocation.isOurs(name), name)
        }
    }

    // MARK: - Порог приёмки: четыре ответа на нажатие

    /// Непустой архив в источнике, пустая цель — можно нести, и вот что.
    func testНепустойАрхивВПустуюПапкуПереноситсяЦеликом() {
        let verdict = ArchiveRelocation.verdict(
            from: .init(path: "/a", filenames: [
                "recordings.json", "deleted.json", "20260821_103440.wav",
                "20260821_103440.mic.wav",
            ]),
            to: .init(path: "/b", filenames: [])
        )
        guard case .carry(let plan) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertEqual(Set(plan.carried), [
            "recordings.json", "deleted.json", "20260821_103440.wav", "20260821_103440.mic.wav",
        ])
        XCTAssertEqual(plan.leftBehind, [])
        XCTAssertEqual(plan.joins, 0)
    }

    /// Индекс уходит последним: пока файлы едут, путь ещё старый, и до
    /// последнего мгновения старая папка обязана оставаться читаемым архивом.
    func testИндексУходитПоследним() {
        let ordered = ArchiveRelocation.ordered([
            "recordings.json", "20260821_103440.wav", "deleted.json",
            "recordings.json.bak", "projects.json",
        ])
        XCTAssertEqual(ordered.last, "recordings.json")
        XCTAssertEqual(ordered.first, "20260821_103440.wav")
    }

    /// Чужое остаётся позади — и человек узнаёт об этом до нажатия, а не после.
    func testЧужиеФайлыОстаютсяВСтаройПапкеИНазываютсяВслух() {
        let verdict = ArchiveRelocation.verdict(
            from: .init(path: "/vault", filenames: [
                "20260821_103440-разбор.md", "Идеи.md", "Daily.md",
            ]),
            to: .init(path: "/vault2", filenames: [])
        )
        guard case .carry(let plan) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertEqual(plan.carried, ["20260821_103440-разбор.md"])
        XCTAssertEqual(plan.leftBehind, ["Daily.md", "Идеи.md"])
    }

    /// Непустая цель без столкновений — нести можно, но «папка не пустая» это
    /// то, что хотят знать до, а не после.
    func testНепустаяЦельБезСтолкновенийНазываетСколькоТамУжеЛежит() {
        let verdict = ArchiveRelocation.verdict(
            from: .init(path: "/a", filenames: ["recordings.json"]),
            to: .init(path: "/b", filenames: ["Заметка.md", "Другая.md"])
        )
        guard case .carry(let plan) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertEqual(plan.joins, 2)
    }

    /// Непустая цель с чужим архивом — отказ. Перенос затёр бы чужой
    /// `recordings.json`, а транскрипты лежат строками в нём: это чужой архив
    /// целиком.
    func testВПапкеСЧужимАрхивомПереноситьОтказываемся() {
        let verdict = ArchiveRelocation.verdict(
            from: .init(path: "/a", filenames: ["recordings.json", "20260821_103440.wav"]),
            to: .init(path: "/b", filenames: ["recordings.json", "20260101_101010.wav"])
        )
        XCTAssertEqual(verdict, .refused(.targetHoldsArchive(colliding: ["recordings.json"])))
    }

    /// Ткнули в ту же папку. Собственные файлы архива не должны прочитаться как
    /// столкновение имён, иначе продукт отказывает сам себе.
    func testТаЖеПапкаЭтоНеСтолкновениеИменИНеПеренос() {
        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: .init(path: "/a/archive", filenames: ["recordings.json"]),
                to: .init(path: "/a/archive/", filenames: ["recordings.json"])
            ),
            .sameFolder
        )
        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: .init(path: "/a/archive", filenames: ["recordings.json"]),
                to: .init(path: "/a/./archive", filenames: ["recordings.json"])
            ),
            .sameFolder
        )
    }

    /// В цель нельзя писать. Отказ раньше, чем «переносить нечего»: в такую
    /// папку не ляжет и следующая запись, и пустой архив это не спасает.
    func testВНепишущуюПапкуПутьНеМеняетсяДажеЕслиАрхивПуст() {
        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: .init(path: "/a", filenames: ["recordings.json"]),
                to: .init(path: "/b", filenames: [], isWritable: false)
            ),
            .refused(.targetNotWritable)
        )
        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: .init(path: "/a", filenames: []),
                to: .init(path: "/b", filenames: [], isWritable: false)
            ),
            .refused(.targetNotWritable)
        )
    }

    /// Нашего в старой папке нет — менять путь можно молча, и спрашивать не о чем.
    func testПустойАрхивМеняетПапкуБезВопросов() {
        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: .init(path: "/vault", filenames: ["Идеи.md"]),
                to: .init(path: "/vault2", filenames: [])
            ),
            .nothingToCarry
        )
    }

    // MARK: - Кто ещё пишет в архив, пока он едет

    /// Идущая запись — отказ, а не очередь. Конвейер на время переноса
    /// останавливают (`AppState.quiescingArchive`), а рекордер остановить
    /// нечем: файл пишется прямо сейчас, и уехавший из-под него — потерянная
    /// встреча.
    func testПокаИдётЗаписьАрхивНеПереносится() {
        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: .init(path: "/a", filenames: ["recordings.json", "20260821_103440.wav"]),
                to: .init(path: "/b", filenames: []),
                sourceIsBusy: true
            ),
            .refused(.sourceIsBusy)
        )
    }

    /// Отказ про источник, поэтому раньше всего, что выясняется про цель: цель
    /// может быть какой угодно, ответ один.
    func testОтказПоЗаписиНеЗависитОтТогоЧтоВЦелевойПапке() {
        for target in [
            ArchiveRelocation.Folder(path: "/b", filenames: []),
            .init(path: "/b", filenames: ["recordings.json"]),
            .init(path: "/b", filenames: [], isWritable: false),
        ] {
            XCTAssertEqual(
                ArchiveRelocation.verdict(
                    from: .init(path: "/a", filenames: ["recordings.json"]),
                    to: target,
                    sourceIsBusy: true
                ),
                .refused(.sourceIsBusy),
                target.path + " \(target.filenames)"
            )
        }
    }

    /// Кроме одного: ткнули в ту же папку — не происходит ничего, и отказывать
    /// не в чем. Отказ здесь читался бы как поломка.
    func testТаЖеПапкаВоВремяЗаписиНеОтказ() {
        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: .init(path: "/a", filenames: ["recordings.json"]),
                to: .init(path: "/a", filenames: ["recordings.json"]),
                sourceIsBusy: true
            ),
            .sameFolder
        )
    }

    /// Записи нет — всё как было. Значение по умолчанию не меняет ни одного
    /// прежнего ответа.
    func testБезЗаписиВердиктПрежний() {
        let folders = (
            source: ArchiveRelocation.Folder(path: "/a", filenames: ["recordings.json"]),
            target: ArchiveRelocation.Folder(path: "/b", filenames: [])
        )
        XCTAssertEqual(
            ArchiveRelocation.verdict(from: folders.source, to: folders.target),
            ArchiveRelocation.verdict(
                from: folders.source, to: folders.target, sourceIsBusy: false
            )
        )
    }

    // MARK: - Перенос на настоящем каталоге

    /// Каталоги во временной папке. Ничего вне `root` не создаётся и не читается.
    private final class Fixture {
        let root: URL
        let source: URL
        let target: URL

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("propeller-relocation-\(UUID().uuidString)", isDirectory: true)
            source = root.appendingPathComponent("recordings", isDirectory: true)
            target = root.appendingPathComponent("elsewhere", isDirectory: true)
            try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: target.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        func plant(_ name: String, in dir: URL, _ body: String = "x") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? body.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }

        func names(in dir: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        }
    }

    func testПереносДоводитАрхивДоНовойПапкиЦеликом() throws {
        let fx = Fixture()
        let files = [
            "recordings.json", "deleted.json",
            "20260821_103440.wav", "20260821_103440-разбор.md",
        ]
        for name in files { fx.plant(name, in: fx.source) }
        fx.plant("Идеи.md", in: fx.source)

        let verdict = ArchiveRelocation.verdict(
            from: ArchiveRelocation.survey(fx.source.path),
            to: ArchiveRelocation.survey(fx.target.path)
        )
        guard case .carry(let plan) = verdict else { return XCTFail("\(verdict)") }

        let outcome = ArchiveRelocation.perform(plan, from: fx.source.path, to: fx.target.path)
        XCTAssertTrue(outcome.isComplete, outcome.stoppedAt ?? "")
        XCTAssertEqual(fx.names(in: fx.target), files.sorted())
        // Чужая заметка не тронута — её никто не просил переносить.
        XCTAssertEqual(fx.names(in: fx.source), ["Идеи.md"])
    }

    /// Половина архива тут, половина там — состояние хуже обоих исходных:
    /// путь читают семнадцать мест, и каждое увидело бы ровно половину.
    func testНеудачаВозвращаетУжеПереехавшееНазад() throws {
        let fx = Fixture()
        fx.plant("20260821_103440.wav", in: fx.source)
        fx.plant("recordings.json", in: fx.source, "наш индекс")
        // В цели уже лежит файл с тем же именем — `moveItem` на нём откажет.
        // Вердикт до такого плана не допустил бы (`targetHoldsArchive`), но
        // между решением и переносом файл мог появиться.
        fx.plant("recordings.json", in: fx.target, "чужой индекс")

        let plan = ArchiveRelocation.Plan(
            carried: ArchiveRelocation.ordered(["20260821_103440.wav", "recordings.json"])
        )
        let outcome = ArchiveRelocation.perform(plan, from: fx.source.path, to: fx.target.path)

        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.stoppedAt, "recordings.json")
        XCTAssertEqual(outcome.stranded, [])
        // Архив снова целиком в старой папке, чужой индекс не тронут.
        XCTAssertEqual(fx.names(in: fx.source), ["20260821_103440.wav", "recordings.json"])
        XCTAssertEqual(fx.names(in: fx.target), ["recordings.json"])
        XCTAssertEqual(
            try String(contentsOf: fx.target.appendingPathComponent("recordings.json")),
            "чужой индекс"
        )
    }

    func testНепишущаяПапкаВиднаДоПереноса() throws {
        try XCTSkipIf(getuid() == 0, "root пишет куда угодно — правило не проверить")
        let fx = Fixture()
        fx.plant("recordings.json", in: fx.source)
        fx.plant("чужое", in: fx.target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: fx.target.path
        )

        XCTAssertEqual(
            ArchiveRelocation.verdict(
                from: ArchiveRelocation.survey(fx.source.path),
                to: ArchiveRelocation.survey(fx.target.path)
            ),
            .refused(.targetNotWritable)
        )
    }

    /// Папки ещё нет — спрашиваем родителя: «туда нельзя писать» надо узнать
    /// до переноса, а не в его середине.
    func testУНесуществующейПапкиСпрашиваютРодителя() {
        let fx = Fixture()
        let folder = ArchiveRelocation.survey(fx.target.path)
        XCTAssertEqual(folder.filenames, [])
        XCTAssertTrue(folder.isWritable)
    }
}
