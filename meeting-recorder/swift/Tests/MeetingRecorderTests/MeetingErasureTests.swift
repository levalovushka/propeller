import XCTest
@testable import PropellerPure

/// # После стирания встречи не остаётся ни одного её следа
///
/// Свойство одно, и оно проверяется двумя способами сразу, потому что каждый из
/// них ловит свою половину будущей ошибки.
///
/// **По видам.** Фикстура обязана создать каждый `MeetingTrace` — `switch` в
/// `plant` исчерпывающий, без `default`. Добавит кто-нибудь новый вид следа
/// (атомы — первые на очереди) — этот файл **не соберётся**, пока не сказано, где
/// след лежит и как его завести. Не тест упадёт, а компилятор откажет.
///
/// **По содержанию.** После стирания весь каталог фикстуры обходится байтами и в
/// нём не должно найтись ни id встречи, ни характерной фразы из её расшифровки.
/// Это ловит вторую половину: производную, которую завели, но в перечислении не
/// назвали. Именно поэтому в фикстуре есть файл `<id>-atoms.json`, о котором
/// `MeetingTrace` ничего не знает.
///
/// Ни один тест здесь не смотрит за пределы своего временного каталога.
final class MeetingErasureTests: XCTestCase {

    // MARK: - Фикстура

    /// Встреча, у которой на диске есть всё.
    struct Meeting {
        let id: String
        let slug: String
        /// Фраза, которая больше нигде в архиве не встречается. Ею проверяется,
        /// что содержимое ушло, а не только имя файла.
        let sentinel: String

        var transcriptName: String { "\(id)-\(slug).md" }
        var recapName: String { "\(id)-\(slug)-recap.md" }
    }

    /// Архив во временном каталоге. Ничего вне `root` не создаётся и не читается.
    final class Fixture {
        let root: URL
        let layout: ArchiveLayout

        init(_ label: String = #function) {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("propeller-erasure-\(UUID().uuidString)", isDirectory: true)
            layout = ArchiveLayout(
                recordings: root.appendingPathComponent("recordings", isDirectory: true),
                meetings: root.appendingPathComponent("meetings", isDirectory: true),
                // В бою `shares.json` лежит в Application Support, а не в архиве.
                // Здесь — внутри фикстуры, чтобы обход по содержанию его видел:
                // запись о публикации несёт id встречи и обязана попасть в
                // проверку наравне с остальными следами.
                shares: root.appendingPathComponent("shares.json")
            )
            for dir in [layout.recordings, layout.meetings] {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        // MARK: Завести след

        /// Создать след указанного вида.
        ///
        /// **`switch` без `default` — это и есть защита от забытой производной.**
        /// Новый case в `MeetingTrace` ломает сборку здесь, и автор обязан
        /// сказать, где его след живёт.
        func plant(_ trace: MeetingTrace, for meeting: Meeting) {
            switch trace {
            case .audioMix:
                writeAudio("\(meeting.id).wav", meeting)
            case .audioMicrophoneStem:
                writeAudio("\(meeting.id).mic.wav", meeting)
            case .audioSystemStem:
                writeAudio("\(meeting.id).sys.wav", meeting)
            case .callWindowTrace:
                write(
                    "{\"meta\":{\"trusted\":true}}\n{\"t\":0.0,\"tiles\":[]}\n",
                    to: layout.recordings.appendingPathComponent("\(meeting.id).calltrace.jsonl")
                )
            case .transcriptDocument:
                write(
                    "# \(meeting.slug)\n\n## Transcript\n\n**Иван Петров** · 00:12\n\(meeting.sentinel)\n",
                    to: layout.meetings.appendingPathComponent(meeting.transcriptName)
                )
            case .recapDocument:
                write(
                    "## Итог\n\n\(meeting.sentinel)\n\n### Решения\n- Иван Петров сверит смету\n",
                    to: layout.meetings.appendingPathComponent(meeting.recapName)
                )
            case .indexEntry:
                appendToIndex(entry(for: meeting), at: layout.indexURL)
            case .indexSnapshotEntry:
                appendToIndex(
                    entry(for: meeting),
                    at: layout.recordings.appendingPathComponent("recordings.json.bak")
                )
            case .tombstone:
                TombstoneFile.mark(meeting.id, in: layout, at: Date(timeIntervalSince1970: 0))
            case .publishedShare:
                publish(meeting, expiresAt: Date().addingTimeInterval(30 * 86400))
            }
        }

        /// Опубликованное саммари: запись с токеном отзыва в `shares.json`.
        /// Через чтение-слияние, а не перезапись: у соседней встречи публикация
        /// тоже может быть, и затирать её нечем.
        func publish(_ meeting: Meeting, expiresAt: Date, erasedAt: Date? = nil) {
            var records = ShareStore.read(layout.shares)
            records[meeting.id] = ShareRecord(
                id: "aZ09-_aZ09-_aZ09-_aZ0\(records.count)",
                token: "token-\(meeting.id)",
                key: ShareLink.base64url(Data(repeating: 0xAB, count: 32)),
                expiresAt: expiresAt,
                title: "Синк с Иваном Петровым",
                erasedAt: erasedAt
            )
            ShareStore.write(records, to: layout.shares)
        }

        func plantEverything(for meeting: Meeting) {
            for trace in MeetingTrace.allCases { plant(trace, for: meeting) }
        }

        /// Производная, которой в `MeetingTrace` нет. Так будут выглядеть атомы.
        func plantFutureDerivative(for meeting: Meeting) -> String {
            let name = "\(meeting.id)-atoms.json"
            write(
                #"[{"claim":"\#(meeting.sentinel)","author":"Иван Петров","at":12.5}]"#,
                to: layout.meetings.appendingPathComponent(name)
            )
            return name
        }

        // MARK: Записать

        func write(_ text: String, to url: URL) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Wav не настоящий — стиранию его формат безразличен, а фраза внутри
        /// нужна, чтобы обход по содержанию проверял и бинарные файлы.
        private func writeAudio(_ name: String, _ meeting: Meeting) {
            var data = Data("RIFF....WAVEfmt ".utf8)
            data.append(Data(meeting.sentinel.utf8))
            try? data.write(to: layout.recordings.appendingPathComponent(name))
        }

        func entry(for meeting: Meeting) -> [String: Any] {
            [
                "id": meeting.id,
                "filename": "\(meeting.id).wav",
                "date": "2026-01-01T12:00:00Z",
                "duration": 600,
                "title": "Синк с Иваном Петровым",
                "status": "summarized",
                "transcript": "[Иван Петров] [00:12]\n\(meeting.sentinel)",
                "notes": "[00:20] спросить Ивана про смету",
                "noteItems": [[
                    "id": "note-1",
                    "text": "спросить Ивана про смету",
                    "createdAt": "2026-01-01T12:20:00Z",
                    "offsetSeconds": 20,
                ]],
                "topics": ["смета", "Иван"],
                "tags": ["1:1"],
                "rawSegmentsJSON": #"[{"start":0,"end":3,"text":"Иван, привет","stem":"microphone"}]"#,
                "mergedSegmentsJSON":
                    #"[{"index":0,"startTime":0,"endTime":3,"text":"\#(meeting.sentinel)","speaker":"Иван Петров"}]"#,
                "liveSegmentsJSON":
                    #"[{"index":0,"startTime":0,"endTime":3,"text":"привет","speaker":"Иван Петров"}]"#,
                "speakerAttribution": "diarized",
                "calendarMeta": [
                    "eventID": "EV-1",
                    "title": "Синк",
                    "organizer": "Иван Петров",
                    "attendees": ["Иван Петров", "Левон"],
                    "isRecurring": false,
                ],
            ]
        }

        func appendToIndex(_ entry: [String: Any], at url: URL) {
            var entries = IndexFile.entries(at: url) ?? []
            entries.append(entry)
            IndexFile.write(entries, to: url)
        }

        // MARK: Обход по содержанию

        /// Файлы каталога фикстуры, чьё имя или содержимое несёт эту строку.
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
                if url.lastPathComponent.contains(needle) {
                    hits.append(url.lastPathComponent)
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                if data.range(of: pattern) != nil { hits.append(url.lastPathComponent) }
            }
            return hits.sorted()
        }
    }

    private let victim = Meeting(
        id: "20260101_120000", slug: "sink-s-ivanom",
        sentinel: "мандариновая-подпись-жертвы"
    )
    private let bystander = Meeting(
        id: "20260202_090000", slug: "planirovanie",
        sentinel: "черешневая-подпись-соседки"
    )

    // MARK: - Свойство

    /// Один след после стирания остаётся законно: копия саммари на сервере.
    /// Убрать её можно только по сети, а удаление сети не ждёт, — поэтому запись
    /// в `shares.json` переживает встречу и остаётся тем, чем публикацию ещё
    /// можно снять. Всё остальное обязано исчезнуть.
    func testПослеСтиранияНеОстаётсяНиОдногоСледаКромеНеснятойПубликации() throws {
        let fx = Fixture()
        fx.plantEverything(for: victim)
        let future = fx.plantFutureDerivative(for: victim)
        fx.plantEverything(for: bystander)

        // Сначала убеждаемся, что фикстура и правда содержит всё: тест, у
        // которого нечего стирать, зелёный по недоразумению.
        let before = ArchiveEraser.residue(of: victim.id, in: fx.layout)
        XCTAssertEqual(
            before.kinds, Set(MeetingTrace.allCases),
            "фикстура не завела: \(Set(MeetingTrace.allCases).subtracting(before.kinds).map(\.rawValue))"
        )
        XCTAssertEqual(
            before.unclassifiedFiles, [future],
            "производная, о которой перечисление не знает, обязана попасть в отчёт"
        )

        let left = ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertEqual(
            left.kinds, [.publishedShare],
            "с диска обязано уйти всё: осталось \(left.summary)"
        )
        XCTAssertEqual(left.unclassifiedFiles, [])
        XCTAssertEqual(
            fx.grep(victim.id), ["shares.json"],
            "единственный уцелевший след — запись, по которой публикацию ещё можно снять"
        )
        XCTAssertEqual(
            fx.grep(victim.sentinel), [],
            "содержимое встречи всё ещё лежит в архиве"
        )
    }

    func testСтираниеОднойВстречиНеТрогаетСоседнюю() {
        let fx = Fixture()
        fx.plantEverything(for: victim)
        fx.plantEverything(for: bystander)

        ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        let neighbour = ArchiveEraser.residue(of: bystander.id, in: fx.layout)
        XCTAssertEqual(neighbour.kinds, Set(MeetingTrace.allCases))
        XCTAssertFalse(fx.grep(bystander.sentinel).isEmpty)
    }

    func testНоваяПроизводнаяУходитВместеСВстречейБезПравкиСтирания() {
        // Атомы появятся файлом рядом, названным по встрече. Стирание ищет по
        // имени, а не по списку видов, поэтому этот файл уходит кодом, который
        // про атомы ничего не знает. Это и есть требование к дизайну.
        let fx = Fixture()
        fx.plant(.indexEntry, for: victim)
        let future = fx.plantFutureDerivative(for: victim)

        ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertEqual(fx.grep(future), [])
        XCTAssertEqual(fx.grep(victim.sentinel), [])
    }

    // MARK: - Копии индекса

    func testРезервнаяКопияИндексаНеОстаётсяВторымЭкземпляромУдалённого() {
        // `save()` копирует прежний индекс в `.bak` перед записью, так что сразу
        // после удаления там лежала целая запись — с транскриптом. Резерв,
        // хранящий удалённое, это не резерв, а второй экземпляр.
        let fx = Fixture()
        fx.plant(.indexEntry, for: victim)
        fx.plant(.indexSnapshotEntry, for: victim)
        fx.plant(.indexSnapshotEntry, for: bystander)

        ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        let bak = fx.layout.recordings.appendingPathComponent("recordings.json.bak")
        XCTAssertEqual(IndexFile.ids(at: bak), [bystander.id], "из копии вынута ровно одна запись")
    }

    func testКарантиннаяКопияЧиститсяПоэлементноИНеУдаляетсяЦеликом() {
        // Карантин — единственный путь восстановления **всех остальных** встреч
        // (`load()` квалифицирует битый индекс). Стирание одной не имеет права
        // его уносить, поэтому из файла вынимается запись, а файл остаётся.
        let fx = Fixture()
        let quarantine = fx.layout.recordings
            .appendingPathComponent("recordings.json.corrupt-2026-01-01T00-00-00Z")
        fx.appendToIndex(fx.entry(for: victim), at: quarantine)
        fx.appendToIndex(fx.entry(for: bystander), at: quarantine)
        fx.plant(.indexEntry, for: victim)

        let left = ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertTrue(left.isEmpty, left.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertEqual(IndexFile.ids(at: quarantine), [bystander.id])
    }

    func testНечитаемыйСнимокДокладываетсяАНеСчитаетсяЧистым() {
        // Файл, который не разбирается в массив объектов, вынуть запись не даёт,
        // а удалить его целиком нельзя — неизвестно, что в нём. Единственный
        // честный исход: сказать, что след остался, и оставить надгробие.
        let fx = Fixture()
        fx.plant(.indexEntry, for: victim)
        let broken = fx.layout.recordings.appendingPathComponent("recordings.json.corrupt-broken")
        fx.write(#"[{"id":"20260101_120000","transcript":"обрубок"#, to: broken)

        let left = ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertFalse(left.isEmpty)
        XCTAssertTrue(left.kinds.contains(.indexSnapshotEntry))
        XCTAssertTrue(
            left.kinds.contains(.tombstone),
            "незакрытое стирание обязано остаться помеченным"
        )
        XCTAssertEqual(IndexFile.ids(at: fx.layout.indexURL), [], "живой индекс всё равно вычищен")
    }

    // MARK: - Надгробие

    func testУспешноеСтираниеНеОставляетДажеНадгробия() {
        let fx = Fixture()
        fx.plantEverything(for: victim)

        ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertEqual(TombstoneFile.read(fx.layout.tombstonesURL).map(\.id), [])
    }

    func testНезакрытоеУдалениеДочищаетсяПоНадгробию() {
        // Так выглядит `SIGKILL` между удалением строки индекса и удалением
        // файлов: записи нет, файлы лежат. Раньше их не подчищал никто, кроме
        // скана сирот, и только аудио — расшифровка и конспект оставались всегда.
        let fx = Fixture()
        fx.plant(.audioMix, for: victim)
        fx.plant(.transcriptDocument, for: victim)
        fx.plant(.recapDocument, for: victim)
        fx.plant(.tombstone, for: victim)

        let finished = ArchiveEraser.finishPendingErasures(in: fx.layout)

        XCTAssertEqual(finished, [victim.id])
        XCTAssertEqual(fx.grep(victim.id), [])
        XCTAssertEqual(TombstoneFile.read(fx.layout.tombstonesURL).map(\.id), [])
    }

    func testОтменаУдаленияНеТеряетНиОдногоФайла() {
        // ⌘Z ещё на экране: строки индекса уже нет, файлы обязаны дожить до
        // решения человека. Отмена, которая не может вернуть аудио, — не отмена.
        let fx = Fixture()
        fx.plantEverything(for: victim)

        let finished = ArchiveEraser.finishPendingErasures(in: fx.layout, keeping: victim.id)

        XCTAssertEqual(finished, [])
        XCTAssertEqual(
            ArchiveEraser.residue(of: victim.id, in: fx.layout).kinds,
            Set(MeetingTrace.allCases)
        )
    }

    func testПовторноеСтираниеНичегоНеПишетИНеЖалуется() {
        let fx = Fixture()
        fx.plantEverything(for: victim)

        ArchiveEraser.erase(meeting: victim.id, in: fx.layout)
        let second = ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        // Неснятая публикация — не повод заводить всё заново: она уже помечена,
        // и второй заход не ставит камня, а повторяет тот же отчёт.
        XCTAssertEqual(second.kinds, [.publishedShare])
        XCTAssertEqual(TombstoneFile.read(fx.layout.tombstonesURL).map(\.id), [])
    }

    // MARK: - Публикация

    /// Порог задачи: удаление встречи с живой публикацией обязано оставить след,
    /// по которому её можно отозвать, и сказать об этом в отчёте.
    ///
    /// До этого `shares.json` не знал ни `ArchiveEraser`, ни `RecordingStore`:
    /// человек публиковал саммари на месяц, слал ссылку коллегам, удалял встречу
    /// — и `residue` отдавал пусто. Копия жила на сервере до конца срока, ссылка
    /// работала, а снять её было уже нечем: `unpublish` звался ровно из кнопки в
    /// плите встречи, а плиты больше нет.
    func testУдалениеВстречиОставляетТоЧемПубликациюМожноСнять() throws {
        let fx = Fixture()
        fx.plantEverything(for: victim)
        let token = try XCTUnwrap(ShareStore.read(fx.layout.shares)[victim.id]).token

        let left = ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertTrue(
            left.kinds.contains(.publishedShare),
            "отчёт обязан сказать, что копия саммари осталась на сервере"
        )
        let queue = ShareStore.awaitingRevocation(at: fx.layout.shares)
        let kept = try XCTUnwrap(queue[victim.id], "очередь отзыва пуста — снимать публикацию нечем")
        XCTAssertEqual(kept.token, token, "токен отзыва обязан пережить встречу")
        XCTAssertNotNil(kept.url, "по записи обязана собираться та же ссылка")
        XCTAssertNotNil(kept.erasedAt, "запись обязана помнить, что встречу стёрли")
    }

    /// Камень остаётся ради дочистки, а дочистка в сеть не ходит. Держать его
    /// над неснятой публикацией значит оставить его на весь срок ссылки — и
    /// заново заводить стирание на каждом скане сирот.
    func testНеснятаяПубликацияНеДержитНадгробие() {
        let fx = Fixture()
        fx.plantEverything(for: victim)

        ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertEqual(TombstoneFile.read(fx.layout.tombstonesURL).map(\.id), [])
        XCTAssertEqual(
            ArchiveEraser.finishPendingErasures(in: fx.layout), [],
            "дочищать нечего: локально всё стёрто, а публикацию она снять не может"
        )
    }

    /// Удаление не имеет права ждать сети: сети может не быть вовсе. Здесь это
    /// проверяется единственным способом, который вообще существует со стороны
    /// стирания, — `erase` синхронный, `await` ему взять неоткуда, и он
    /// возвращается сразу. Сам отзыв заводит `RecordingStore` уже после.
    func testСтираниеНеЖдётСети() {
        let fx = Fixture()
        fx.plantEverything(for: victim)

        let started = Date()
        let left = ArchiveEraser.erase(meeting: victim.id, in: fx.layout)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.0, "стирание ушло куда-то ждать: \(elapsed) с")
        XCTAssertEqual(left.kinds, [.publishedShare])
        XCTAssertEqual(fx.grep(victim.sentinel), [], "файлы стёрты, а не отложены до сети")
    }

    /// Сборка без публикаций (`Bench`, MCP, чужая фикстура) — `shares` не задан.
    /// Стирание обязано работать ровно как раньше и не спотыкаться об отсутствие
    /// файла, которого в этой сборке и не бывает.
    func testБезСпискаПубликацийСтираниеРаботаетКакРаньше() {
        let fx = Fixture()
        let bare = ArchiveLayout(recordings: fx.layout.recordings, meetings: fx.layout.meetings)
        fx.plant(.indexEntry, for: victim)
        fx.plant(.audioMix, for: victim)

        let left = ArchiveEraser.erase(meeting: victim.id, in: bare)

        XCTAssertTrue(left.isEmpty, left.summary)
        XCTAssertEqual(fx.grep(victim.id), [])
    }

    /// Просроченная ссылка — не след: бэкапов у сервера нет осознанно, копии уже
    /// не существует, отзывать нечего. Метить такую запись стиранием тоже
    /// незачем — её выметает сервис.
    func testПросроченнаяПубликацияСледомНеСчитается() {
        let fx = Fixture()
        fx.plant(.indexEntry, for: victim)
        fx.publish(victim, expiresAt: Date().addingTimeInterval(-3600))

        let left = ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        XCTAssertTrue(left.isEmpty, left.summary)
        XCTAssertNil(ShareStore.read(fx.layout.shares)[victim.id]?.erasedAt)
        XCTAssertEqual(ShareStore.awaitingRevocation(at: fx.layout.shares).count, 0)
    }

    func testСтираниеОднойВстречиНеТрогаетПубликациюСоседней() throws {
        let fx = Fixture()
        fx.plantEverything(for: victim)
        fx.plantEverything(for: bystander)

        ArchiveEraser.erase(meeting: victim.id, in: fx.layout)

        let neighbour = try XCTUnwrap(ShareStore.read(fx.layout.shares)[bystander.id])
        XCTAssertNil(neighbour.erasedAt)
        XCTAssertEqual(
            ShareStore.awaitingRevocation(at: fx.layout.shares).map(\.key), [victim.id]
        )
    }

    // MARK: - Правило принадлежности

    func testФайлПринадлежитВстречеТолькоЧерезРазделитель() {
        XCTAssertTrue(MeetingErasure.belongs("20260101_120000.wav", to: "20260101_120000"))
        XCTAssertTrue(MeetingErasure.belongs("20260101_120000.mic.wav", to: "20260101_120000"))
        XCTAssertTrue(MeetingErasure.belongs("20260101_120000-sink.md", to: "20260101_120000"))
        XCTAssertTrue(MeetingErasure.belongs("20260101_120000-atoms.json", to: "20260101_120000"))
        // Без разделителя это чужое имя, начинающееся так же.
        XCTAssertFalse(MeetingErasure.belongs("20260101_1200009.wav", to: "20260101_120000"))
        // Индекс и надгробия — не файлы встречи.
        XCTAssertFalse(MeetingErasure.belongs("recordings.json", to: "20260101_120000"))
        XCTAssertFalse(MeetingErasure.belongs("deleted.json", to: "20260101_120000"))
    }

    func testКопиейИндексаСчитаетсяЛюбойСнимокКромеЖивого() {
        XCTAssertFalse(ArchiveLayout.isIndexSnapshot("recordings.json"))
        for name in [
            "recordings.json.bak",
            "recordings.json.corrupt-2026-01-01T00-00-00Z",
            "recordings.json.pre-restore-20260805_192338",
        ] {
            XCTAssertTrue(ArchiveLayout.isIndexSnapshot(name), name)
        }
        XCTAssertFalse(ArchiveLayout.isIndexSnapshot("deleted.json"))
    }
}
