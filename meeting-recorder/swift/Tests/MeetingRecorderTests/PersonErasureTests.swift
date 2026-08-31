import XCTest
@testable import PropellerPure

/// # После «стереть человека» его имени нет ни в одной встрече
///
/// Человек в этой модели данных — текст, разложенный по девяти местам, и восемь
/// из них не файлы, а поля одной строки индекса. Поэтому проверка идёт не по
/// полям, а по **файлам целиком**: если имя ещё где-то лежит, сырой байтовый
/// поиск его найдёт независимо от того, знал ли о таком поле автор стирания.
///
/// Это и есть готовность к атомам с другой стороны: чистка индекса обходит JSON
/// вообще, а не список известных полей, поэтому поле, добавленное после этого
/// кода, чистится само. Тест сторожит именно это — в фикстуре есть поле, которого
/// в `RecordingEntry` нет.
final class PersonErasureTests: XCTestCase {

    private let ivan = "Иван Петров"
    private let owner = "Левон"

    // MARK: - Правило поиска

    func testПадежныеФормыИмениСчитаютсяТемЖеИменем() {
        let name = PersonName(ivan)
        for form in ["Иван", "Ивана", "Ивану", "Иваном", "Иване", "Петров", "Петрова", "Петровым"] {
            XCTAssertTrue(
                PersonErasure.contains("вчера \(form) сказал, что", name: name),
                form
            )
        }
    }

    func testСловоНачинающеесяКакИмяНеСчитаетсяИменем() {
        let name = PersonName(ivan)
        // Иначе «январь» стал бы «Участникрь», а стирание одного человека
        // испортило бы прозу всех конспектов архива.
        for word in ["январь", "января", "Ивановский", "Петровско-Разумовская"] {
            XCTAssertFalse(
                PersonErasure.contains("сдвинули на \(word)", name: name),
                word
            )
        }
    }

    func testРегистрИЁНеМешают() {
        XCTAssertTrue(PersonErasure.contains("АЛЁНА сказала", name: PersonName("Алена")))
        XCTAssertTrue(PersonErasure.contains("алена сказала", name: PersonName("Алёна")))
    }

    func testЖенскоеИмяЛовитсяТожеХотяОкончаниеУНегоМеняется() {
        // «Алёна» → «Алёны»: окончание не дописывается, а заменяется, поэтому
        // правило «имя плюс хвост» само по себе не сработало бы вовсе.
        let name = PersonName("Алёна Смирнова")
        for form in ["Алёна", "Алёны", "Алёне", "Алёной", "Смирнова", "Смирновой"] {
            XCTAssertTrue(PersonErasure.contains("это сказала \(form)", name: name), form)
        }
    }

    func testКороткаяЧастьИмениСамаПоСебеНеСтирается() {
        // «Ян» как отдельное слово встречается по другим поводам, а стирание
        // необратимо. Полная форма при этом работает.
        let name = PersonName("Ян Ковальский")
        XCTAssertFalse(PersonErasure.contains("Ян приедет", name: name))
        XCTAssertTrue(PersonErasure.contains("Ян Ковальский приедет", name: name))
        XCTAssertTrue(PersonErasure.contains("Ковальский приедет", name: name))
    }

    func testПолноеИмяВыигрываетУСвоейЧасти() {
        // Короткая форма, применённая первой, оставила бы «Участник Петров».
        let out = PersonErasure.redacted("[Иван Петров] [00:12]", name: PersonName(ivan))
        XCTAssertEqual(out, "[Участник] [00:12]")
    }

    func testМеткаСпикераОстаётсяМеткойАНеПустотой() {
        // `[] [12:34]` — сломанная расшифровка: её разбирает регулярка
        // `MarkdownWriter.formatTranscriptBodySimple` и парсер сегментов.
        let out = PersonErasure.redacted(
            "[Иван Петров] [12:34]\nпривет", name: PersonName(ivan), with: "Участник"
        )
        XCTAssertTrue(out.hasPrefix("[Участник] [12:34]"))
    }

    // MARK: - Обход JSON

    func testПолеПоявившеесяПослеЭтогоКодаЧиститсяСамо() {
        // Атом, ссылка на проект, что угодно: строка чистится по факту того, что
        // она строка. Обратный порядок — «чистим перечисленное» — и есть та
        // конструкция, из-за которой атомы завтра остались бы с именами.
        let entry: [String: Any] = [
            "id": "20260101_120000",
            "atomsJSON": #"[{"claim":"смета","author":"Иван Петров"}]"#,
            "чего-такого-ещё-не-было": ["автор": "Иван Петров"],
        ]
        let out = PersonErasure.redactedJSON(entry, name: PersonName(ivan)) as? [String: Any]
        XCTAssertEqual(out?["atomsJSON"] as? String, #"[{"claim":"смета","author":"Участник"}]"#)
        XCTAssertEqual(
            (out?["чего-такого-ещё-не-было"] as? [String: Any])?["автор"] as? String,
            "Участник"
        )
    }

    func testИдентификаторыНеТрогаются() {
        // Замена внутри `id` или `filename` — это не приватность, а потеря
        // встречи: по ним ищут файлы на диске.
        let entry: [String: Any] = [
            "id": "иван-1", "filename": "иван-1.wav", "status": "summarized",
            "eventID": "иван-event", "title": "Синк с Иваном",
        ]
        let out = PersonErasure.redactedJSON(entry, name: PersonName("Иван")) as? [String: Any]
        XCTAssertEqual(out?["id"] as? String, "иван-1")
        XCTAssertEqual(out?["filename"] as? String, "иван-1.wav")
        XCTAssertEqual(out?["eventID"] as? String, "иван-event")
        // «Участник», а не «Участником»: окончание съедено вместе с именем.
        // Согласовать замену значило бы разбирать падеж — см. `PersonName`.
        XCTAssertEqual(out?["title"] as? String, "Синк с Участник")
    }

    // MARK: - Сквозняк по архиву

    func testПослеСтиранияЧеловекаЕгоИмениНетНиВОдномФайлеАрхива() throws {
        let fx = Fixture()
        fx.plantMeeting(id: "20260101_120000", slug: "sink-s-ivanom")
        fx.plantMeeting(id: "20260202_090000", slug: "retro")
        fx.plantSnapshot(id: "20260303_100000")

        XCTAssertFalse(
            ArchivePersonEraser.remaining(person: ivan, in: fx.layout).isEmpty,
            "фикстура обязана содержать имя, иначе тест зелёный по недоразумению"
        )

        let report = ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertTrue(report.isComplete, "осталось: \(report.remaining)")
        XCTAssertEqual(fx.grep(ivan), [], "имя ещё лежит в архиве")
        XCTAssertEqual(fx.grep("Иваном"), [], "падежная форма ещё лежит в архиве")
        XCTAssertGreaterThan(report.entriesChanged, 0)
    }

    func testВладелецЗаписиИДругиеЛюдиОстаютсяНаМесте() {
        let fx = Fixture()
        fx.plantMeeting(id: "20260101_120000", slug: "sink-s-ivanom")

        ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertFalse(fx.grep(owner).isEmpty, "стирание одного не имеет права уносить всех")
    }

    func testИмяВИмениФайлаТожеУходит() {
        // Slug собирается из заголовка и кириллицу не выбрасывает, поэтому «1:1 с
        // Иваном» доезжает до диска именем файла, которое видно в Finder и в
        // Obsidian. Совпадение по id при этом не ломается: он ищется префиксом.
        let fx = Fixture()
        fx.plantMeeting(id: "20260101_120000", slug: "1-1-s-иваном")

        ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        let names = ArchiveEraser.filenames(in: fx.layout.meetings)
        XCTAssertFalse(names.contains { $0.contains("иваном") }, "\(names)")
        XCTAssertTrue(
            names.contains { RecapFile.isTranscript($0, for: "20260101_120000") },
            "расшифровка обязана остаться находимой по id: \(names)"
        )
    }

    func testСтираниеЧеловекаНеТрогаетНиОдногоАудиофайла() {
        // Речь остаётся речью: уходит личность, не встреча. Забрать аудио — это
        // отдельная операция с отдельным правилом (`AudioReclaim`).
        let fx = Fixture()
        fx.plantMeeting(id: "20260101_120000", slug: "sink")
        let before = ArchiveEraser.filenames(in: fx.layout.recordings).sorted()

        ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertEqual(ArchiveEraser.filenames(in: fx.layout.recordings).sorted(), before)
    }


    // MARK: - Трасса окна звонилки

    func testИмяУходитИзТрассыОкнаЗвонилки() {
        // 22 трассы на 52 МБ против 4,9 МБ всей папки `meetings/` — и до
        // 2026-08-31 стирание в них не заглядывало вовсе. Замер на живом
        // архиве: по одному человеку стиралось 3 348 вхождений и оставалось
        // 54 388 в восьми трассах.
        let fx = Fixture()
        fx.plantMeeting(id: "20260101_120000", slug: "sink")
        fx.plantCallTrace(id: "20260101_120000")

        let report = ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertEqual(fx.grep(ivan), [], "имя ещё лежит в архиве")
        XCTAssertTrue(report.isComplete, "осталось: \(report.remaining)")
        XCTAssertTrue(
            report.filesChanged.contains("20260101_120000.calltrace.jsonl"),
            "\(report.filesChanged)"
        )
    }

    func testПроверкаНаходитИмяВТрассеЕслиЕгоНеСтёрли() {
        // `remaining` обязан смотреть туда же, куда смотрит стирание. Раньше
        // он смотрел мимо трассы — и `isComplete` был правдой про неполный
        // список мест, а не про архив.
        let fx = Fixture()
        fx.plantCallTrace(id: "20260101_120000")

        XCTAssertEqual(
            ArchivePersonEraser.remaining(person: ivan, in: fx.layout),
            ["20260101_120000.calltrace.jsonl"]
        )
    }

    func testПослеСтиранияЖурналСчитаетТеЖеВердиктыПодНейтральнойПодписью() {
        // Почему подмена имени, а не удаление плитки: состав опроса — вход
        // правил `CallWindowJournal.verdict`. Убрав плитку, мы поменяли бы
        // вердикт про **других** людей: у геометрии есть порог в две названные
        // плитки, у метки Zoom — счёт помеченных.
        let fx = Fixture()
        fx.plantCallTrace(id: "20260101_120000")
        let url = fx.layout.recordings.appendingPathComponent("20260101_120000.calltrace.jsonl")
        let before = CallWindowJournal.polls(fromJSONL: (try? Data(contentsOf: url)) ?? Data())

        ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        let after = CallWindowJournal.polls(fromJSONL: (try? Data(contentsOf: url)) ?? Data())
        XCTAssertEqual(after.count, before.count, "трасса обязана остаться той же записью")
        XCTAssertEqual(
            after.map { $0.tiles.count }, before.map { $0.tiles.count },
            "число плиток менять нельзя — от него зависит вердикт"
        )
        XCTAssertEqual(
            CallWindowJournal.verdict(in: before[0]), .speaker("Иван Петров")
        )
        XCTAssertEqual(
            CallWindowJournal.verdict(in: after[0]), .speaker(PersonErasure.defaultReplacement),
            "тот же вердикт, только подпись нейтральная"
        )
        // Владелец на второй плитке — на месте: стирание одного не трогает всех.
        XCTAssertTrue(
            after[0].tiles.contains { $0.description.hasPrefix(owner) }, "\(after[0].tiles)"
        )
    }

    func testОборваннаяСтрокаТрассыВсёРавноЧистится() {
        // Трасса — запись, и убитый процесс оставляет недописанный хвост.
        // `CallWindowJournal.polls` такую строку пропускает; стирание не имеет
        // права, иначе имя переживёт стирание в куске, который «всё равно не
        // читается».
        let fx = Fixture()
        fx.plantCallTrace(id: "20260101_120000", tornTail: true)

        let report = ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertEqual(fx.grep(ivan), [])
        XCTAssertTrue(report.isComplete, "осталось: \(report.remaining)")
    }

    // MARK: - Честность отчёта

    func testОтчётНеОбъявляетПолнотуПокаИмяХотьГдеТоЛежит() {
        // Снимок, не разбирающийся в массив объектов, вынуть запись не даёт —
        // и это ровно тот случай, когда соврать «стёрто везде» дороже всего.
        let fx = Fixture()
        fx.plantMeeting(id: "20260101_120000", slug: "sink")
        fx.plantBrokenSnapshot()

        let report = ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertFalse(report.isComplete, "отчёт обязан признаться")
        XCTAssertEqual(report.remaining, ["recordings.json.corrupt-1"])
    }

    // MARK: - Проекты и заглушенные связки

    func testЗаглушеннаяСвязкаТеряетИмяВместеСЗаголовком() {
        // Ключ — свёрнутый заголовок. Заголовок после стирания стал
        // «1x1 с Участник», значит и ключ обязан стать таким же свёрнутым,
        // иначе «больше не предлагать» перестанет совпадать и связка всплывёт.
        let fx = Fixture()
        fx.plantSilenced(key: "title:1x1 с иваном")

        ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertEqual(
            SilencedProjects.read(fx.layout.silencedProjectsURL),
            ["title:1x1 с " + ArchiveSearch.fold(PersonErasure.defaultReplacement)]
        )
        XCTAssertEqual(fx.grep("иваном"), [])
    }

    func testИмяПроектаТеряетЧеловекаАСамПроектОстаётся() {
        let fx = Fixture()
        fx.plantProject(name: "1x1 с Иваном")

        let report = ArchivePersonEraser.erase(person: ivan, in: fx.layout)

        XCTAssertTrue(report.filesChanged.contains(ArchiveLayout.projectsName))
        let text = (try? String(contentsOf: fx.layout.projectsURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("1x1 с Участник"), text)
        XCTAssertTrue(text.contains("P-1"), "id проекта — не текст про человека: \(text)")
    }

    // MARK: - Якорь владельца

    /// Единственное место архива, куда сквозняк не дотягивается: Zoom-имя
    /// владельца лежит в `UserDefaults`, а не в файле. Стёрли человека, чьё имя
    /// там записано, — имя оставалось.
    func testЯкорьВладельцаСнимаетсяВместеСЧеловеком() {
        XCTAssertNil(
            PersonErasure.clearedAnchor("Levon Lobanov", name: PersonName("Levon Lobanov"))
        )
        // Часть имени — тот же человек, тем же правилом, что и везде.
        XCTAssertNil(PersonErasure.clearedAnchor("Левон Лобанов", name: PersonName("Левон")))
    }

    /// Стёрли не того, кто в якоре, — якорь на месте. Иначе первое же стирание
    /// сбрасывало бы опознание своей плитки у всех подряд.
    func testЧужоеСтираниеЯкорьНеТрогает() {
        XCTAssertEqual(
            PersonErasure.clearedAnchor("Levon Lobanov", name: PersonName(ivan)),
            "Levon Lobanov"
        )
    }

    /// Замена якорю не годится. «Участник» после стирания носит **каждый**
    /// стёртый, и такой якорь объявил бы владельцем чужую плитку на следующей
    /// же встрече — а `MeetingRoster` схлопнул бы этого человека в ряд владельца
    /// задним числом по всему архиву.
    func testЯкорьСнимаетсяАНеЗаменяетсяНейтральнымИменем() {
        let cleared = PersonErasure.clearedAnchor("Иван Петров", name: PersonName(ivan))
        XCTAssertNil(cleared)
        XCTAssertNotEqual(cleared, PersonErasure.defaultReplacement)
    }

    func testПустогоЯкоряНеБывает() {
        XCTAssertNil(PersonErasure.clearedAnchor(nil, name: PersonName(ivan)))
        XCTAssertNil(PersonErasure.clearedAnchor("", name: PersonName(ivan)))
    }

    // MARK: - Обход

    func testКаждыйВидСледаЕстьВФикстуреИНиОдинНеЗабыт() {
        // Тот же сторож, что у `MeetingTrace`: новый вид следа не пройдёт мимо
        // теста молча. Пока вид не посажен в фикстуру, тест красный, а значит
        // никто не добавит место, которое стирание обходит стороной.
        let fx = Fixture()
        fx.plantMeeting(id: "20260101_120000", slug: "sink")
        fx.plantSnapshot(id: "20260202_090000")
        fx.plantCallTrace(id: "20260101_120000")
        fx.plantProject(name: "1x1 с Иваном")
        fx.plantSilenced(key: "title:1x1 с иваном")
        fx.plantTombstone(id: "20260303_100000")

        for trace in PersonTrace.allCases {
            XCTAssertFalse(
                trace.places(in: fx.layout).isEmpty,
                "вид следа \(trace.rawValue) не посажен в фикстуру"
            )
        }
    }

    // MARK: - Фикстура

    final class Fixture {
        let root: URL
        let layout: ArchiveLayout

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("propeller-person-\(UUID().uuidString)", isDirectory: true)
            layout = ArchiveLayout(
                recordings: root.appendingPathComponent("recordings", isDirectory: true),
                meetings: root.appendingPathComponent("meetings", isDirectory: true)
            )
            for dir in [layout.recordings, layout.meetings] {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func plantMeeting(id: String, slug: String) {
            let doc = """
            # Синк с Иваном Петровым

            **Participants:** Иван Петров, Левон
            **Organizer:** Иван Петров

            ## Transcript

            **Иван Петров** · 00:12
            привет, я Иван
            """
            try? doc.write(
                to: layout.meetings.appendingPathComponent("\(id)-\(slug).md"),
                atomically: true, encoding: .utf8
            )
            try? "## Итог\n\nИван Петров сверит смету с Левоном.\n".write(
                to: layout.meetings.appendingPathComponent("\(id)-\(slug)-recap.md"),
                atomically: true, encoding: .utf8
            )
            try? Data("RIFF....WAVE".utf8).write(
                to: layout.recordings.appendingPathComponent("\(id).wav")
            )
            append(entry(id: id), to: layout.indexURL)
        }


        /// Трасса окна звонилки: заголовок `meta`, дальше опросы. Формат — тот
        /// же, что пишет `axprobe trace`: в `description` имя вместе с
        /// состоянием звука и видео.
        func plantCallTrace(id: String, tornTail: Bool = false) {
            func tile(_ description: String, width: Double, marker: String) -> String {
                """
                {"role":"AXTabGroup","description":"\(description), \(marker)",\
                "width":\(width),"height":414,"window":"Конференция Zoom",\
                "process":"zoom.us","order":1}
                """
            }
            let speaking = tile("Иван Петров", width: 736, marker: "говорит, Video on")
            let listening = tile("Левон Лобанов", width: 200, marker: "Video off")
            var lines = [#"{"meta":{"anchorUnix":1787230814.226375,"interval":0.4}}"#]
            for t in stride(from: 0.0, to: 2.0, by: 0.5) {
                lines.append(#"{"t":\#(t),"tiles":[\#(speaking),\#(listening)]}"#)
            }
            if tornTail {
                // Ровно то, что остаётся от убитого процесса: полстроки.
                lines.append(#"{"t":2.5,"tiles":[{"description":"Иван Петров, гово"#)
            }
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(
                to: layout.recordings.appendingPathComponent("\(id).calltrace.jsonl")
            )
        }

        /// Снимок индекса, который не разбирается в массив объектов: запись из
        /// него вынуть нечем, а имя в нём лежит.
        func plantBrokenSnapshot() {
            try? Data(#"{"oops": "Синк с Иваном Петровым"#.utf8).write(
                to: layout.recordings.appendingPathComponent("recordings.json.corrupt-1")
            )
        }

        func plantProject(name: String) {
            IndexFile.write(
                [["id": "P-1", "name": name, "createdAt": "2026-01-01T12:00:00Z"]],
                to: layout.projectsURL
            )
        }

        func plantSilenced(key: String) {
            SilencedProjects.write([key], to: layout.silencedProjectsURL)
        }

        func plantTombstone(id: String) {
            TombstoneFile.mark(id, in: layout)
        }

        func plantSnapshot(id: String) {
            append(
                entry(id: id),
                to: layout.recordings.appendingPathComponent("recordings.json.bak")
            )
        }

        private func entry(id: String) -> [String: Any] {
            [
                "id": id,
                "filename": "\(id).wav",
                "date": "2026-01-01T12:00:00Z",
                "duration": 600,
                "title": "Синк с Иваном Петровым",
                "status": "summarized",
                "transcript": "[Иван Петров] [00:12]\nпривет\n\n[Левон] [00:20]\nпривет, Иван",
                "notes": "[00:20] спросить Ивана про смету",
                "noteItems": [[
                    "id": "note-1",
                    "text": "спросить у Ивана смету",
                    "createdAt": "2026-01-01T12:20:00Z",
                ]],
                "topics": ["смета Ивана"],
                "rawSegmentsJSON": #"[{"start":0,"end":3,"text":"Иван, привет","stem":"microphone"}]"#,
                "mergedSegmentsJSON":
                    #"[{"index":0,"startTime":0,"endTime":3,"text":"привет","speaker":"Иван Петров"}]"#,
                "liveSegmentsJSON":
                    #"[{"index":0,"startTime":0,"endTime":3,"text":"привет","speaker":"Иван Петров"}]"#,
                "calendarMeta": [
                    "eventID": "EV-1",
                    "title": "Синк с Иваном",
                    "organizer": "Иван Петров",
                    "attendees": ["Иван Петров", "Левон"],
                    "isRecurring": false,
                ],
                // Поля, которого в `RecordingEntry` нет: так будут выглядеть
                // атомы. Чистится тем же обходом, без правки кода стирания.
                "atomsJSON": #"[{"claim":"сверить смету","author":"Иван Петров","at":12.5}]"#,
            ]
        }

        private func append(_ entry: [String: Any], to url: URL) {
            var entries = IndexFile.entries(at: url) ?? []
            entries.append(entry)
            IndexFile.write(entries, to: url)
        }

        /// Файлы, чьё имя или содержимое несёт эту строку.
        func grep(_ needle: String) -> [String] {
            let fm = FileManager.default
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return []
            }
            let pattern = Data(needle.utf8)
            var hits: [String] = []
            for case let url as URL in walker {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue { continue }
                if url.lastPathComponent.localizedCaseInsensitiveContains(needle) {
                    hits.append(url.lastPathComponent)
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                if data.range(of: pattern) != nil { hits.append(url.lastPathComponent) }
            }
            return hits.sorted()
        }
    }
}
