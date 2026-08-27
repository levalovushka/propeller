import XCTest
@testable import PropellerPure

/// Проект — плоский тег, который переживает переименование, откат сборки и
/// стирание человека. Каждый случай ниже про одно из этих трёх.
final class ProjectTests: XCTestCase {

    // MARK: - Сущность

    func testИмяИОписаниеПриходятОбрезанными() {
        let project = Project(name: "  Найм  ", about: "\n Воронка и офферы \n")
        XCTAssertEqual(project.name, "Найм")
        XCTAssertEqual(project.about, "Воронка и офферы")
        XCTAssertFalse(project.archived)
    }

    func testПроектБезИмениНеСуществует() {
        XCTAssertTrue(Project(name: "   ").isEmpty)
        XCTAssertFalse(Project(name: "Найм").isEmpty)
    }

    /// Идентичность не завязана ни на имя, ни на путь: переименование стоит
    /// одной строки в `projects.json` и ничего в индексе встреч.
    func testПереименованиеНеМеняетИдентичность() {
        let before = Project(name: "Найм")
        var after = before
        after.name = "Наём"
        XCTAssertEqual(before.id, after.id)
    }

    // MARK: - Файл

    private func makeLayout() -> ArchiveLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-projects-\(UUID().uuidString)", isDirectory: true)
        let layout = ArchiveLayout(
            recordings: root.appendingPathComponent("recordings", isDirectory: true),
            meetings: root.appendingPathComponent("meetings", isDirectory: true)
        )
        for dir in [layout.recordings, layout.meetings] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return layout
    }

    func testФайлЛежитРядомСИндексом() {
        let layout = makeLayout()
        XCTAssertEqual(layout.projectsURL.lastPathComponent, "projects.json")
        XCTAssertEqual(
            layout.projectsURL.deletingLastPathComponent(),
            layout.indexURL.deletingLastPathComponent()
        )
        // И снимком индекса при этом не считается — иначе стирание принялось бы
        // чистить его как копию `recordings.json`.
        XCTAssertFalse(ArchiveLayout.isIndexSnapshot("projects.json"))
    }

    func testПроектПереживаетКругЧерезДиск() {
        let layout = makeLayout()
        let project = Project(name: "PG x VK", about: "Музыка и регулярка", archived: true)
        XCTAssertTrue(ProjectFile.save(project, in: layout))

        let back = ProjectFile.read(layout.projectsURL)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.id, project.id)
        XCTAssertEqual(back.first?.name, "PG x VK")
        XCTAssertEqual(back.first?.about, "Музыка и регулярка")
        XCTAssertEqual(back.first?.archived, true)
        XCTAssertEqual(
            back.first?.createdAt.timeIntervalSince1970 ?? 0,
            project.createdAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testСохранениеПоТомуЖеIdЗаменяетАНеДобавляет() {
        let layout = makeLayout()
        var project = Project(name: "Найм")
        ProjectFile.save(project, in: layout)
        project.name = "Наём"
        project.archived = true
        ProjectFile.save(project, in: layout)

        let back = ProjectFile.read(layout.projectsURL)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.name, "Наём")
        XCTAssertEqual(back.first?.archived, true)
    }

    func testБезымянныйПроектНеЗаписывается() {
        let layout = makeLayout()
        XCTAssertFalse(ProjectFile.save(Project(name: "  "), in: layout))
        XCTAssertTrue(ProjectFile.read(layout.projectsURL).isEmpty)
    }

    func testУдалениеУбираетТолькоСвойПроект() {
        let layout = makeLayout()
        let keep = Project(name: "Найм")
        let drop = Project(name: "PG x VK")
        ProjectFile.save(keep, in: layout)
        ProjectFile.save(drop, in: layout)

        XCTAssertTrue(ProjectFile.remove(drop.id, in: layout))
        XCTAssertEqual(ProjectFile.read(layout.projectsURL).map(\.id), [keep.id])
        // Удалить то, чего нет, — не ошибка: вызывающий и хотел, чтобы его не было.
        XCTAssertTrue(ProjectFile.remove("нет-такого", in: layout))
    }

    func testПорченыйФайлЧитаетсяКакПустой() {
        let layout = makeLayout()
        try? Data("не json вовсе".utf8).write(to: layout.projectsURL)
        XCTAssertTrue(ProjectFile.read(layout.projectsURL).isEmpty)
    }

    // MARK: - Заглушенные связки

    func testОтказПереживаетКругЧерезДиск() {
        let layout = makeLayout()
        XCTAssertTrue(SilencedProjects.read(layout.silencedProjectsURL).isEmpty)
        XCTAssertTrue(SilencedProjects.silence("series:S-1", in: layout))
        XCTAssertEqual(SilencedProjects.read(layout.silencedProjectsURL), ["series:S-1"])
        // Идемпотентно: второй крестик на той же связке ничего не меняет.
        XCTAssertTrue(SilencedProjects.silence("series:S-1", in: layout))
        XCTAssertEqual(SilencedProjects.read(layout.silencedProjectsURL).count, 1)
    }

    /// Отказы лежат **не** в `projects.json`: заглушенная связка не проект и
    /// никогда им не станет, а список проектов читают все.
    func testОтказыЛежатОтдельноОтПроектов() {
        let layout = makeLayout()
        SilencedProjects.silence("title:дейлик", in: layout)
        XCTAssertNotEqual(layout.silencedProjectsURL, layout.projectsURL)
        XCTAssertTrue(ProjectFile.read(layout.projectsURL).isEmpty)
        XCTAssertFalse(ArchiveLayout.isIndexSnapshot(ArchiveLayout.silencedProjectsName))
    }

    func testПорченыйФайлОтказовЧитаетсяКакПустой() {
        let layout = makeLayout()
        try? Data("не json".utf8).write(to: layout.silencedProjectsURL)
        XCTAssertTrue(SilencedProjects.read(layout.silencedProjectsURL).isEmpty)
    }

    // MARK: - Копия в документе встречи

    func testСписокИмёнЧиститсяПередЗаписью() {
        XCTAssertEqual(
            Project.normalized(["  Найм ", "Найм", "", "  ", "PG x VK"]),
            ["Найм", "PG x VK"]
        )
    }

    func testВстречаБезПроектовНеПолучаетНиОднойЛишнейСтроки() {
        XCTAssertEqual(Project.plainHeaderLines(names: []), [])
        XCTAssertEqual(Project.yamlFrontmatterLines(names: ["  "]), [])

        let doc = MeetingMarkdown.render(
            title: "Синк", transcript: "**Левон** · 00:01\nпривет",
            format: .simple, today: "2026-08-27"
        )
        XCTAssertFalse(doc.contains("Projects"))
    }

    /// Индекс отдаёт id, документ — имя. Обе копии нужны: `RecordingEntry` —
    /// синтезированный `Codable`, и старая сборка молча роняет незнакомое поле
    /// при своей записи индекса. Тег, поставленный руками, вернуть будет неоткуда.
    func testПростойФорматНесётИменаПроектов() {
        let doc = MeetingMarkdown.simple(
            title: "Синк", transcript: "**Левон** · 00:01\nпривет",
            duration: 600, speakers: ["Левон"], notes: nil,
            projectNames: ["Найм", "Найм", " PG x VK "], today: "2026-08-27"
        )
        XCTAssertTrue(doc.contains("**Projects:** Найм, PG x VK"))
        // В шапке, рядом с участниками, а не где-то в теле.
        let head = doc.components(separatedBy: "## Transcript").first ?? ""
        XCTAssertTrue(head.contains("**Projects:**"))
    }

    func testОбсидиановыйФорматНесётИменаПроектовВоФронтматтере() {
        let doc = MeetingMarkdown.obsidian(
            title: "Синк", transcript: "**Левон** · 00:01\nпривет",
            recordingID: "20260827_120000", duration: 600, speakers: ["Левон"],
            notes: nil, projectNames: ["Найм", "Кавычки \"внутри\""],
            today: "2026-08-27", linkedSpeakers: []
        )
        XCTAssertTrue(doc.contains(#"projects: ["Найм", "Кавычки \"внутри\""]"#))
        // Внутри фенсов, до `tags`, иначе это уже не фронтматтер.
        let frontmatter = doc.components(separatedBy: "---")[1]
        XCTAssertTrue(frontmatter.contains("projects: ["))
        XCTAssertTrue(
            frontmatter.range(of: "projects: [")!.lowerBound
                < frontmatter.range(of: "tags: [meeting]")!.lowerBound
        )
    }

    // MARK: - Стирание человека

    /// «1×1 с Иваном» после «стереть Ивана» обязан стать «1×1 с Участник».
    /// Иначе человек остался в архиве под вывеской раздела.
    func testИмяЧеловекаУходитИзИмениПроекта() {
        let layout = makeLayout()
        ProjectFile.save(
            Project(name: "1×1 с Иваном", about: "Регулярка с Иваном"),
            in: layout
        )

        let report = ArchivePersonEraser.erase(person: "Иван", in: layout)

        let back = ProjectFile.read(layout.projectsURL)
        XCTAssertEqual(back.first?.name, "1×1 с Участник")
        XCTAssertEqual(back.first?.about, "Регулярка с Участник")
        XCTAssertTrue(report.filesChanged.contains("projects.json"))
        XCTAssertTrue(report.isComplete, "осталось: \(report.remaining)")
    }

    /// Отчёт «стёрто везде» обязан считать и этот файл. Пока `projects.json` не
    /// был в обходе, отчёт сказал бы «чисто» про архив, в котором имя лежит.
    func testПроверкаСледовВидитИмяВФайлеПроектов() {
        let layout = makeLayout()
        ProjectFile.save(Project(name: "1×1 с Иваном"), in: layout)
        XCTAssertEqual(
            ArchivePersonEraser.remaining(person: "Иван", in: layout),
            ["projects.json"]
        )
    }

    /// Метка на встрече — массив id, а не текст про человека. Замена внутри
    /// него оторвала бы встречу от проекта: id ищут по совпадению, как имя файла.
    func testМеткиПроектовНаВстречеНеЧистятся() {
        let entry: [String: Any] = [
            "id": "20260101_120000",
            "title": "Синк с Иваном",
            "projects": ["иван-1x1", "8F2C"],
        ]
        let out = PersonErasure.redactedJSON(entry, name: PersonName("Иван")) as? [String: Any]
        XCTAssertEqual(out?["projects"] as? [String], ["иван-1x1", "8F2C"])
        XCTAssertEqual(out?["title"] as? String, "Синк с Участник")
    }
}
