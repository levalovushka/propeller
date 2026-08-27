import Foundation

/// A project: the meetings that recur and for which context is worth
/// accumulating (`plan-projects.md` §2). A flat tag — there is no hierarchy,
/// and a client with three projects is three projects.
///
/// The identity is a generated id, not the name and not a path. A project has
/// to survive being renamed, and it has to mean the same thing on the next
/// machine; nothing here may depend on where the archive happens to live
/// (`VISION.md` §10).
///
/// The index stores ids. The meeting document stores names, and that asymmetry
/// is deliberate — see `Project.plainHeaderLines` for why.
public struct Project: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// What the person called it. May be renamed at any time; nothing keys off it.
    public var name: String
    /// The human description typed in the creation dialog («О чём этот проект?»). Skippable — the
    /// product does not fall apart without it (`plan-projects.md` §4.4). The
    /// machine's own summary of a project is a different field and does not
    /// exist yet: it is gated behind §5.
    public var about: String
    /// Archived projects leave the rail but not the data. Only the person
    /// deletes (`plan-projects.md` §8).
    public var archived: Bool
    /// Sorting by activity needs meetings; a project with none still has to
    /// have a stable place in the list.
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        about: String = "",
        archived: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        self.archived = archived
        self.createdAt = createdAt
    }

    /// A project the person cannot see or find. Not persisted, not offered.
    public var isEmpty: Bool { name.isEmpty }

    // MARK: - В документе встречи

    /// `**Projects:** Найм, PG x VK` for the Simple format.
    ///
    /// The index gets ids, the document gets names, and the document is the
    /// copy that survives. `RecordingEntry` has a synthesized `Codable` with no
    /// `CodingKeys`, so an older build that does not know the field **drops it
    /// silently when it writes the index back**. That was judged acceptable for
    /// `recapGeneratorVersion` because the next recap restores it
    /// (`Sources/Models.swift:98-99`) — nothing restores a tag the person put
    /// on by hand. The second copy in the meeting document is what makes a
    /// downgrade survivable, exactly as for `calendarMeta`.
    public static func plainHeaderLines(names: [String]) -> [String] {
        let kept = normalized(names)
        guard !kept.isEmpty else { return [] }
        return ["**Projects:** \(kept.joined(separator: ", "))"]
    }

    /// `projects: ["Найм", "PG x VK"]` for the Obsidian front matter.
    public static func yamlFrontmatterLines(names: [String]) -> [String] {
        let kept = normalized(names)
        guard !kept.isEmpty else { return [] }
        let items = kept.map { "\"\(yamlEscaped($0))\"" }
        return ["projects: [\(items.joined(separator: ", "))]"]
    }

    /// Trimmed, empties dropped, duplicates removed, order kept — the same
    /// treatment `CalendarMeta` gives attendee names.
    public static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    private static func yamlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Связки, на которые человек сказал «нет».
///
/// Живут рядом с проектами и **вне** их: заглушенная связка — это не проект и
/// никогда им не станет, а помнить о ней надо ровно затем, чтобы больше не
/// спрашивать (`plan-projects.md` §3, правило 3). Ключ — тот же, что у
/// предложения (`ProjectCandidate.Suggestion.key`): серия календаря или
/// свёрнутое имя, а не позиция в списке, — поэтому «навсегда» переживает
/// перезапуск.
public enum SilencedProjects {

    public static func read(_ url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(keys)
    }

    @discardableResult
    public static func write(_ keys: Set<String>, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(keys.sorted()) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Больше не предлагать. Идемпотентно.
    @discardableResult
    public static func silence(_ key: String, in layout: ArchiveLayout) -> Bool {
        var keys = read(layout.silencedProjectsURL)
        guard keys.insert(key).inserted else { return true }
        try? FileManager.default.createDirectory(
            at: layout.recordings, withIntermediateDirectories: true
        )
        return write(keys, to: layout.silencedProjectsURL)
    }
}

/// `recordings/projects.json`.
///
/// Its own file, not a corner of the index: a project exists before it has any
/// meetings and outlives the ones it had, so there is nothing in the meeting
/// index for it to hang from. Same directory, same atomic write, same reason —
/// one archive, one place to copy.
///
/// Synchronous and undebounced, like `TombstoneFile`: the whole list is a few
/// hundred bytes, and creating a project is a deliberate act that must not be
/// lost to a crash inside a save window.
public enum ProjectFile {

    public static func read(_ url: URL) -> [Project] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Project].self, from: data)) ?? []
    }

    @discardableResult
    public static func write(_ projects: [Project], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(projects) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Put a project in the file, replacing the one with the same id.
    @discardableResult
    public static func save(_ project: Project, in layout: ArchiveLayout) -> Bool {
        guard !project.isEmpty else { return false }
        var projects = read(layout.projectsURL)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try? FileManager.default.createDirectory(
            at: layout.recordings, withIntermediateDirectories: true
        )
        return write(projects, to: layout.projectsURL)
    }

    /// Take a project out of the file. Meetings keep their tag until somebody
    /// removes it from them too — this function knows nothing about the index,
    /// and a tag pointing at a project that is gone reads as no tag.
    @discardableResult
    public static func remove(_ id: String, in layout: ArchiveLayout) -> Bool {
        let projects = read(layout.projectsURL)
        guard projects.contains(where: { $0.id == id }) else { return true }
        return write(projects.filter { $0.id != id }, to: layout.projectsURL)
    }
}
